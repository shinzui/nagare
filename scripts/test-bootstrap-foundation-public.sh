#!/usr/bin/env bash
# A fresh cloud context has no state bucket, Pulumi stack, host, or Kubernetes.
# Its first public review must contain only the prerequisite cloud foundation.
set -euo pipefail

nagarectl_bin="${1:?pass the built nagarectl executable path}"
real_pulumi="$(command -v pulumi)"
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
  "storage buckets get-iam-policy gs://fixture-project-nagare-pulumi-state --format=json")
    if test -e "$XDG_STATE_HOME/member-granted"; then
      printf '{"bindings":[{"role":"roles/storage.objectAdmin","members":["serviceAccount:deployer@fixture-project.iam.gserviceaccount.com"]}]}\n'
    else
      printf '{"bindings":[]}\n'
    fi
    ;;
  "storage buckets add-iam-policy-binding gs://fixture-project-nagare-pulumi-state "*)
    touch "$XDG_STATE_HOME/member-granted" ;;
  *) printf 'unexpected gcloud command: %s\n' "$*" >&2; exit 37 ;;
esac
EOF
chmod +x "$fixture_root/bin/gcloud"
cat > "$fixture_root/bin/pulumi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if test -n "${NAGARE_REAL_PULUMI:-}"; then
  exec "$NAGARE_REAL_PULUMI" "$@"
fi
printf '%s %s\n' "${PULUMI_BACKEND_URL:-unset}" "$*" >> "$XDG_STATE_HOME/pulumi.log"
case "${3:-} ${4:-}" in
  "stack ls")
    if test -e "$XDG_STATE_HOME/stack-created"; then
      printf '[{"name":"freshlocal","current":false}]\n'
    else
      printf '[]\n'
    fi
    ;;
  "stack init") touch "$XDG_STATE_HOME/stack-created" ;;
  "config set")
    printf '%s\t%s\n' "$7" "$8" >> "$XDG_STATE_HOME/pulumi-config.tsv" ;;
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
  *) printf 'unexpected pulumi command: %s\n' "$*" >&2; exit 38 ;;
esac
EOF
chmod +x "$fixture_root/bin/pulumi"
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
"$nagarectl_bin" --context freshlocal platform bootstrap apply "$fixture_root/local-review" --yes > "$fixture_root/apply-out" 2>&1 || {
  cat "$fixture_root/apply-out" >&2
  cat "$XDG_STATE_HOME/gcloud-apply.log" >&2
  exit 1
}
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
