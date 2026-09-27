#!/usr/bin/env bash
# A fresh local context reviews the registry, cluster, and context kubeconfig.
set -euo pipefail

nagarectl_bin="${1:?pass the built nagarectl executable path}"
interrupt_mode="${2:-cluster}"
case "$interrupt_mode" in cluster|unresolved|marker|native-marker) ;; *) printf 'expected cluster, unresolved, marker, or native-marker interruption\n' >&2; exit 2 ;; esac
real_k3d="$(command -v k3d)"
real_kubectl="$(command -v kubectl)"
real_helm="$(command -v helm)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/nagare-bootstrap-local.XXXXXX")"
native_cluster_created=0
controller_archive_created=0
cleanup_fixture() {
  if [ "$native_cluster_created" = 1 ]; then
    "$real_k3d" cluster delete nagare-bootstrap-marker-smoke >/dev/null
  fi
  if [ "$controller_archive_created" = 1 ]; then rm -f "$controller_archive"; fi
  rm -rf "$fixture_root"
}
trap cleanup_fixture EXIT
export XDG_CONFIG_HOME="$fixture_root/config"
export XDG_STATE_HOME="$fixture_root/state"
export NAGARE_PLATFORM_ROOT="$(pwd)"
controller_archive="$NAGARE_PLATFORM_ROOT/cluster/bootstrap/net-certmanager/nagare-net-certmanager-controller.tar.gz"
if test -L "$controller_archive"; then
  printf 'controller fixture archive path is a symlink\n' >&2
  exit 1
fi
if test ! -e "$controller_archive"; then
  printf 'fixture controller image archive\n' > "$controller_archive"
  controller_archive_created=1
fi
if [ "$interrupt_mode" = native-marker ]; then
  if "$real_k3d" cluster list -o json | jq -e '.[] | select(.name == "nagare-bootstrap-marker-smoke")' >/dev/null; then
    printf 'native marker smoke cluster already exists\n' >&2
    exit 1
  fi
  native_cluster_created=1
  "$real_k3d" cluster create nagare-bootstrap-marker-smoke \
    --image rancher/k3s:v1.34.6-k3s1 --kubeconfig-update-default=false \
    --kubeconfig-switch-context=false --timeout 120s >/dev/null
  export NAGARE_TEST_NATIVE_MARKER=1
  export NAGARE_TEST_REAL_K3D="$real_k3d"
  export NAGARE_TEST_REAL_KUBECTL="$real_kubectl"
fi
export PATH="$fixture_root/bin:$PATH"
export NAGARE_REAL_HELM="$real_helm"
export NAGARE_MODE=local
export NAGARE_PULUMI_BACKEND=local
export NAGARE_INVENTORY_STORE=local
export NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000
export NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io
export NAGARE_LOCAL_OBJECT_STORE=http://minio.nagare-system.svc.cluster.local:9000/nagare-backups
mkdir -p "$XDG_CONFIG_HOME/nagare/contexts" "$fixture_root/bin" "$XDG_STATE_HOME"
cat > "$XDG_CONFIG_HOME/nagare/contexts/localfresh.env" <<'EOF'
NAGARE_MODE=local
NAGARE_PULUMI_BACKEND=local
NAGARE_INVENTORY_STORE=local
NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000
NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io
NAGARE_LOCAL_OBJECT_STORE=http://minio.nagare-system.svc.cluster.local:9000/nagare-backups
NAGARE_PLATFORM_VERSION=0.4.0
EOF
cat > "$fixture_root/bin/k3d" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XDG_STATE_HOME/k3d.log"
case "$*" in
  "registry list -o json")
    if test -e "$XDG_STATE_HOME/registry-created"; then
      printf '[{"name":"k3d-registry.localhost","portMappings":{"5000/tcp":[{"HostIp":"0.0.0.0","HostPort":"5000"}]}}]\n'
    else printf '[]\n'; fi ;;
  "cluster list -o json")
    if test -e "$XDG_STATE_HOME/cluster-created"; then
      python3 - "$XDG_STATE_HOME/cluster-digest" <<'PY'
import json
import pathlib
import sys
digest = pathlib.Path(sys.argv[1]).read_text().strip()
print(json.dumps([{"name": "nagare-local", "serversCount": 1,
  "serversRunning": 1, "hasLoadbalancer": True,
  "nodes": [
    {"role": "server", "State": {"Running": True},
     "runtimeLabels": {"nagare.bootstrap.digest": digest}},
    {"role": "loadbalancer", "portMappings": {
      "80/tcp": [{"HostPort": "80"}],
      "443/tcp": [{"HostPort": "443"}]}}]}]))
PY
    else printf '[]\n'; fi ;;
  "registry create registry.localhost --port 0.0.0.0:5000 --no-help")
    touch "$XDG_STATE_HOME/registry-created"
    if test -e "$XDG_STATE_HOME/fail-registry-ack"; then
      mv "$XDG_STATE_HOME/fail-registry-ack" "$XDG_STATE_HOME/failed-registry-ack"
      printf 'simulated lost registry acknowledgement\n' >&2
      exit 41
    fi ;;
  "cluster create nagare-local "*)
    [[ " $* " == *" --registry-use k3d-registry.localhost:5000 "* ]]
    [[ " $* " == *" --kubeconfig-update-default=false "* ]]
    for argument in "$@"; do
      case "$argument" in
        nagare.bootstrap.digest=*@server:0)
          digest="${argument#nagare.bootstrap.digest=}"
          printf '%s\n' "${digest%@server:0}" > "$XDG_STATE_HOME/cluster-digest" ;;
      esac
    done
    test -s "$XDG_STATE_HOME/cluster-digest"
    touch "$XDG_STATE_HOME/cluster-created" ;;
  "kubeconfig get nagare-local")
    if [ "${NAGARE_TEST_NATIVE_MARKER:-}" = 1 ]; then
      "$NAGARE_TEST_REAL_K3D" kubeconfig get nagare-bootstrap-marker-smoke
      exit
    fi
    cat <<'YAML'
apiVersion: v1
kind: Config
clusters:
  - name: k3d-nagare-local
    cluster:
      server: https://127.0.0.1:54321
      certificate-authority-data: Y2E=
users:
  - name: admin@k3d-nagare-local
    user:
      client-certificate-data: Y2VydA==
      client-key-data: a2V5
contexts:
  - name: k3d-nagare-local
    context:
      cluster: k3d-nagare-local
      user: admin@k3d-nagare-local
current-context: k3d-nagare-local
YAML
    ;;
  *) printf 'unexpected k3d command: %s\n' "$*" >&2; exit 43 ;;
esac
EOF
chmod +x "$fixture_root/bin/k3d"

"$nagarectl_bin" --context localfresh platform bootstrap plan --out "$fixture_root/substrate-review" \
  > "$fixture_root/substrate-plan-out" 2>&1 || {
  cat "$fixture_root/substrate-plan-out" >&2
  exit 1
}
python3 - "$fixture_root/substrate-review/review.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = [item["operation"] for item in review["operations"]]
assert len(operations) == 2, operations
assert {item["executor"] for item in operations} == {"ArtifactExecutor"}, operations
assert {tuple(item["resources"]) for item in operations} == {
    ("platform:local-substrate/registry/k3d-registry.localhost",),
    ("platform:local-substrate/cluster/nagare-local",),
}, operations
registry = next(item for item in operations if "/registry/" in item["resources"][0])
cluster = next(item for item in operations if "/cluster/" in item["resources"][0])
assert cluster["dependencies"] == [registry["id"]], cluster
PY
test ! -e "$XDG_STATE_HOME/registry-created"
test ! -e "$XDG_STATE_HOME/cluster-created"
cp "$XDG_CONFIG_HOME/nagare/contexts/localfresh.env" \
  "$XDG_CONFIG_HOME/nagare/contexts/otherlocal.env"
if "$nagarectl_bin" --context otherlocal platform bootstrap apply "$fixture_root/substrate-review" --yes \
  > "$fixture_root/wrong-context-out" 2>&1; then
  printf 'local substrate review unexpectedly applied to another context\n' >&2
  exit 1
fi
test ! -e "$XDG_STATE_HOME/registry-created"
cp "$XDG_CONFIG_HOME/nagare/contexts/localfresh.env" "$fixture_root/localfresh.env.saved"
sed 's/NAGARE_PLATFORM_VERSION=0.4.0/NAGARE_PLATFORM_VERSION=0.4.1/' \
  "$fixture_root/localfresh.env.saved" > "$XDG_CONFIG_HOME/nagare/contexts/localfresh.env"
if "$nagarectl_bin" --context localfresh platform bootstrap apply "$fixture_root/substrate-review" --yes \
  > "$fixture_root/changed-pin-out" 2>&1; then
  printf 'changed local payload pin unexpectedly applied the substrate review\n' >&2
  exit 1
fi
test ! -e "$XDG_STATE_HOME/registry-created"
cp "$fixture_root/localfresh.env.saved" "$XDG_CONFIG_HOME/nagare/contexts/localfresh.env"
printf 'changed local payload pin refused before k3d mutation\n'
touch "$XDG_STATE_HOME/fail-registry-ack"
if "$nagarectl_bin" --context localfresh platform bootstrap apply "$fixture_root/substrate-review" --yes \
  > "$fixture_root/substrate-apply-out" 2>&1; then
  printf 'local registry apply unexpectedly acknowledged a simulated lost result\n' >&2
  exit 1
fi
test -e "$XDG_STATE_HOME/registry-created"
test ! -e "$XDG_STATE_HOME/cluster-created"
transaction="$(python3 - "$XDG_STATE_HOME/nagare/localfresh/inventory/head.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    head = json.load(source)
assert head["activeTransaction"] is not None, head
print(head["activeTransaction"])
PY
)"
"$nagarectl_bin" --context localfresh inventory resume "$transaction" --yes \
  > "$fixture_root/substrate-resume-out" 2>&1 || {
  cat "$fixture_root/substrate-apply-out" >&2
  cat "$fixture_root/substrate-resume-out" >&2
  cat "$XDG_STATE_HOME/k3d.log" >&2
  "$fixture_root/bin/k3d" cluster list -o json >&2
  exit 1
}
test -e "$XDG_STATE_HOME/cluster-created"
test "$(grep -Fc 'registry create registry.localhost' "$XDG_STATE_HOME/k3d.log")" -eq 1
test "$(grep -Fc 'cluster create nagare-local' "$XDG_STATE_HOME/k3d.log")" -eq 1
printf 'public local bootstrap resumed registry creation and converged the cluster\n'
mv "$XDG_STATE_HOME/registry-created" "$XDG_STATE_HOME/registry-created.saved"
"$nagarectl_bin" --context localfresh platform bootstrap plan --out "$fixture_root/registry-drift-review" \
  > "$fixture_root/registry-drift-out" 2>&1 || {
  cat "$fixture_root/registry-drift-out" >&2
  exit 1
}
python3 - "$fixture_root/registry-drift-review/review.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = [item["operation"] for item in review["operations"]]
assert len(operations) == 1, operations
assert operations[0]["resources"] == ["platform:local-substrate/registry/k3d-registry.localhost"], operations
PY
mv "$XDG_STATE_HOME/registry-created.saved" "$XDG_STATE_HOME/registry-created"
printf 'observed local registry absence planned one reviewed repair\n'

"$nagarectl_bin" --context localfresh platform bootstrap plan --out "$fixture_root/kubeconfig-review" \
  > "$fixture_root/kubeconfig-plan-out" 2>&1 || {
  cat "$fixture_root/kubeconfig-plan-out" >&2
  exit 1
}
python3 - "$fixture_root/kubeconfig-review/review.json" <<'PY'
import glob
import json
import os
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
operations = [item["operation"] for item in review["operations"]]
assert len(operations) == 1, operations
assert operations[0]["executor"] == "ArtifactExecutor", operations
assert operations[0]["resources"] == ["platform:kubeconfig/context-kubeconfig/localfresh"], operations
assert len(operations[0]["dependencies"]) == 0, operations
managed = []
for path in glob.glob(os.path.join(os.path.dirname(sys.argv[1]), "scopes", "*.json")):
    with open(path, encoding="utf-8") as source:
        scope = json.load(source)
    managed.extend(declaration["contents"] for bundle in scope["bundles"]
                   for declaration in bundle["declarations"] if declaration["tag"] == "Managed")
kubeconfig = [resource for resource in managed if resource["identity"] ==
              "platform:kubeconfig/context-kubeconfig/localfresh"]
assert len(kubeconfig) == 1, kubeconfig
assert {"tag": "OrderedAfter", "contents":
        "platform:local-substrate/cluster/nagare-local"} in kubeconfig[0]["dependencies"]
PY
destination="$XDG_CONFIG_HOME/nagare/kubeconfigs/localfresh.yaml"
test ! -e "$destination"
"$nagarectl_bin" --context localfresh platform bootstrap apply "$fixture_root/kubeconfig-review" --yes \
  > "$fixture_root/kubeconfig-apply-out" 2>&1 || {
  cat "$fixture_root/kubeconfig-apply-out" >&2
  exit 1
}
test -s "$destination"
test "$(KUBECONFIG="$destination" kubectl config current-context)" = localfresh
if [ "$interrupt_mode" = native-marker ]; then
  KUBECONFIG="$destination" "$real_kubectl" --context localfresh \
    create namespace nagare-system >/dev/null
fi
if grep -Fq 'a2V5' "$fixture_root/kubeconfig-review/review.json"; then
  printf 'public local kubeconfig review exposed credential bytes\n' >&2
  exit 1
fi
printf 'public local bootstrap installed its reviewed context kubeconfig\n'
export NAGARE_TEST_KUBECONFIG_DESTINATION="$destination"

cp "$NAGARE_PLATFORM_ROOT/scripts/test-bootstrap-kubectl-fixture.py" "$fixture_root/bin/kubectl"
cat > "$fixture_root/bin/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XDG_STATE_HOME/helm.log"
case "$*" in
  "status "*" -o json")
    release="$2"
    namespace=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --namespace ]; then namespace="$2"; break; fi
      shift
    done
    receipt="$XDG_STATE_HOME/helm-${namespace}-${release}.txt"
    if [ -f "$receipt" ]; then
      jq -n --arg description "$(cat "$receipt")" \
        '{version:1,info:{status:"deployed",description:$description}}'
    else printf 'Error: release: not found\n' >&2; exit 1; fi ;;
  "upgrade --install "*)
    release="$3"
    namespace=""
    description=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --namespace) namespace="$2"; shift ;;
        --description) description="$2"; shift ;;
      esac
      shift
    done
    test -n "$namespace" && test -n "$description"
    printf '%s\n' "$description" > "$XDG_STATE_HOME/helm-${namespace}-${release}.txt" ;;
  *) exec "$NAGARE_REAL_HELM" "$@" ;;
esac
EOF
cat > "$fixture_root/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XDG_STATE_HOME/skopeo.log"
case "$*" in
  *" inspect --format {{.Digest}} docker-archive:"*)
    printf 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
  *"inspect --tls-verify=false --format {{.Digest}} docker://"*)
    if [ -f "$XDG_STATE_HOME/oci-published" ]; then
      printf 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    else printf 'manifest unknown\n' >&2; exit 1; fi ;;
  *" copy --preserve-digests "*) touch "$XDG_STATE_HOME/oci-published" ;;
  *) printf 'unexpected skopeo command: %s\n' "$*" >&2; exit 43 ;;
esac
EOF
cat > "$fixture_root/bin/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = -d
case "${2##*/}" in
  grafana-admin.yaml)
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: grafana-admin\n  namespace: monitoring\nstringData:\n  admin-user: fixture\n  admin-password: fixture-password\n' ;;
  *) exit 43 ;;
esac
EOF
chmod +x "$fixture_root/bin/kubectl" "$fixture_root/bin/helm" "$fixture_root/bin/skopeo" "$fixture_root/bin/sops"
export NAGARE_CLUSTER_SECRETS_DIR="$fixture_root/cluster-secrets"
mkdir -p "$NAGARE_CLUSTER_SECRETS_DIR"
touch "$NAGARE_CLUSTER_SECRETS_DIR/grafana-admin.yaml"
export NAGARE_AUTH_EN_IMAGE="fixture.invalid/en@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
export NAGARE_AUTH_SHOMEI_IMAGE="fixture.invalid/shomei@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
export NAGARE_AUTH_ACCESS_IMAGE="fixture.invalid/nagare-access@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
if ! "$nagarectl_bin" --context localfresh platform bootstrap plan --out "$fixture_root/cluster-review" \
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
assert len(operations) == 209, len(operations)
assert collections.Counter(item["executor"] for item in operations) == {
    "KubernetesExecutor": 202,
    "HelmExecutor": 5,
    "ArtifactExecutor": 2,
}
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
edge = {"tag": "OrderedAfter", "contents": "platform:kubeconfig/context-kubeconfig/localfresh"}
cluster_members = [resource for resource in managed if resource["executor"] in
                   ("KubernetesExecutor", "HelmExecutor")]
assert cluster_members, managed
assert all(edge in resource["dependencies"] for resource in cluster_members)
marker_members = [resource for resource in managed if resource["identity"] == marker_id]
assert len(marker_members) == 1, marker_members
assert edge in marker_members[0]["dependencies"]
PY
printf 'public local bootstrap planned 209 cluster operations after its kubeconfig\n'

sed 's/NAGARE_PLATFORM_VERSION=0.4.0/NAGARE_PLATFORM_VERSION=0.4.1/' \
  "$fixture_root/localfresh.env.saved" > "$XDG_CONFIG_HOME/nagare/contexts/localfresh.env"
if "$nagarectl_bin" --context localfresh platform bootstrap apply "$fixture_root/cluster-review" --yes \
  > "$fixture_root/changed-cluster-pin-out" 2>&1; then
  printf 'changed platform pin unexpectedly applied the cluster review\n' >&2
  exit 1
fi
test ! -e "$XDG_STATE_HOME/kubectl-writes"
cp "$fixture_root/localfresh.env.saved" "$XDG_CONFIG_HOME/nagare/contexts/localfresh.env"
printf 'changed cluster payload pin refused before Kubernetes mutation\n'
if [ "$interrupt_mode" = cluster ] || [ "$interrupt_mode" = unresolved ]; then
  touch "$XDG_STATE_HOME/fail-cluster-ack"
else
  touch "$XDG_STATE_HOME/fail-marker-before"
fi
if "$nagarectl_bin" --context localfresh platform bootstrap apply "$fixture_root/cluster-review" --yes \
  > "$fixture_root/cluster-apply-out" 2>&1; then
  printf 'cluster apply unexpectedly acknowledged the simulated interruption\n' >&2
  exit 1
fi
if [ "$interrupt_mode" = cluster ] || [ "$interrupt_mode" = unresolved ]; then
  test -e "$XDG_STATE_HOME/failed-cluster-ack"
else
  test -e "$XDG_STATE_HOME/failed-marker-before"
  test ! -e "$XDG_STATE_HOME/kubectl-objects/configmap__nagare-system__nagare-platform-version.json"
fi
transaction="$(python3 - "$XDG_STATE_HOME/nagare/localfresh/inventory/head.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    head = json.load(source)
assert head["activeTransaction"] is not None, head
print(head["activeTransaction"])
PY
)"
if [ "$interrupt_mode" = unresolved ]; then
  touch "$XDG_STATE_HOME/unresolved-get"
  if "$nagarectl_bin" --context localfresh inventory resume "$transaction" --yes \
    > "$fixture_root/unresolved-resume-out" 2>&1; then
    printf 'unresolved Kubernetes write unexpectedly resumed\n' >&2
    exit 1
  fi
  test ! -e "$XDG_STATE_HOME/kubectl-objects/configmap__nagare-system__nagare-platform-version.json"
  test "$(wc -l < "$XDG_STATE_HOME/kubectl-writes")" -eq 1
  rm -f "$XDG_STATE_HOME/unresolved-get"
  printf 'unresolved cluster result refused without another write\n'
fi
if ! "$nagarectl_bin" --context localfresh inventory resume "$transaction" --yes \
  > "$fixture_root/cluster-resume-out" 2>&1; then
  cat "$fixture_root/cluster-apply-out" >&2
  cat "$fixture_root/cluster-resume-out" >&2
  exit 1
fi
test -s "$XDG_STATE_HOME/kubectl-objects/configmap__nagare-system__nagare-platform-version.json"
test "$(grep -Fc 'configmap/nagare-platform-version' "$XDG_STATE_HOME/kubectl-writes")" -eq 1
if [ "$interrupt_mode" = native-marker ]; then
  KUBECONFIG="$destination" "$real_kubectl" --context localfresh -n nagare-system \
    get configmap nagare-platform-version -o json | jq -e \
      '.data.payloadId == "source-development" and .data.version == "0.4.0"' >/dev/null
  printf 'disposable native k3d API stores the reviewed final marker\n'
fi
python3 - "$XDG_STATE_HOME/nagare/localfresh/inventory/head.json" \
  "$XDG_STATE_HOME/kubectl-objects/configmap__nagare-system__nagare-platform-version.json" <<'PY'
import hashlib
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    head = json.load(source)
assert head["activeTransaction"] is None, head
assert head["accepted"] == head["converged"], head
with open(sys.argv[2], encoding="utf-8") as source:
    marker = json.load(source)
data = marker["data"]
assert data["payloadId"] == "source-development", data
assert data["version"] == "0.4.0", data
assert data["installedAt"], data
vector = [{"scope": entry["scope"], "generation": entry["revision"]["generation"],
           "digest": entry["revision"]["digest"]} for entry in head["accepted"]
          if entry["scope"]["kind"] == "Platform"
          and entry["scope"]["name"] != "bootstrap-stamp"]
vector.sort(key=lambda entry: (entry["scope"]["kind"], entry["scope"]["name"]))
digest = hashlib.sha256(json.dumps(vector, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
assert data["scopeVectorDigest"] == digest, data
PY
printf 'public local bootstrap resumed %s interruption and converged the marker\n' "$interrupt_mode"

"$nagarectl_bin" --context localfresh platform bootstrap plan --out "$fixture_root/unchanged-review" \
  > "$fixture_root/unchanged-plan-out" 2>&1 || {
  cat "$fixture_root/unchanged-plan-out" >&2
  exit 1
}
python3 - "$fixture_root/unchanged-review/review.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    review = json.load(source)
actions = {item["operation"]["action"]["tag"] for item in review["operations"]}
assert actions == {"VerifyResource"}, actions
assert any("platform:bootstrap-stamp/bootstrap/version" in item["operation"]["resources"]
           for item in review["operations"])
PY
printf 'unchanged bootstrap planned no provider updates\n'
