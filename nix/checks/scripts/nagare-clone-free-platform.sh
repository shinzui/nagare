#!/usr/bin/env bash
set -euo pipefail

mkdir -p isolated/home isolated/config isolated/state isolated/empty
export HOME="$PWD/isolated/home"
export XDG_CONFIG_HOME="$PWD/isolated/config"
export XDG_STATE_HOME="$PWD/isolated/state"
export NAGARE_FAKE_TOOL_LOG="$PWD/isolated/tools.log"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
touch "$NAGARE_FAKE_TOOL_LOG"
cd isolated/empty

nagarectl context create local \
  --mode local \
  --registry-host localhost:5000 \
  --base-domain 127-0-0-1.sslip.io \
  --local-object-store http://minio:9000/nagare-backups
nagarectl context use local
if nagarectl platform root --json > root.json 2> root.err; then
  :
else
  platform_root_status="$?"
  echo "nagarectl platform root exited with status $platform_root_status" >&2
  cat root.err >&2
  test ! -s root.json || cat root.json >&2
  exit "$platform_root_status"
fi
jq -e '.source == "installed" and (.workspaceRoot | type == "string" and length > 0)' root.json >/dev/null || {
  echo "nagarectl platform root returned unexpected JSON:" >&2
  cat root.json >&2
  exit 1
}
workspace_root="$(jq -er '.workspaceRoot' root.json)"
test -f "$workspace_root/cluster/examples/uploads-volume/nagare/Config.hs"
test ! -e "$workspace_root/cluster/secrets"
mkdir -p "$XDG_CONFIG_HOME/nagare/cluster-secrets/local"
resolved_secrets="$({
  export NAGARE_PLATFORM_ROOT="$workspace_root"
  export NAGARE_WORKSPACE_ROOT="$workspace_root"
  . "$workspace_root/scripts/lib/target.sh"
  . "$workspace_root/scripts/lib/cluster-secrets.sh"
  nagare_cluster_secrets_dir
})"
test "$resolved_secrets" = "$XDG_CONFIG_HOME/nagare/cluster-secrets/local"
grep -q 'run-reviewed-bootstrap.sh' "$workspace_root/cluster/observability/install.sh"
# EP-112: the ACME contact is mandatory. Non-interactively, with
# no --acme-email, `init` must refuse and name the flag; there is
# no safe default for somebody's mailbox.
if nagarectl init trial --project example --dry-run --skip-preflight \
  > init-no-acme.out 2> init-no-acme.err; then
  echo "nagarectl init unexpectedly accepted a missing ACME contact" >&2
  cat init-no-acme.out init-no-acme.err >&2
  exit 1
fi
grep -q -- '--acme-email' init-no-acme.err
nagarectl init trial --project example --acme-email ops@example.com \
  --dry-run --skip-preflight > init.out
grep -q 'config set --stack trial nagare:machineType e2-standard-2' init.out
grep -q 'config set --stack trial nagare:bootDiskType pd-balanced' init.out
grep -q 'config set --stack trial nagare:bootDiskSizeGb 100' init.out
grep -q 'config set --stack trial nagare:dataDiskSizeGb 100' init.out
grep -q 'DRY RUN: would run:' init.out
grep -q "$XDG_STATE_HOME/nagare/trial/platform/" init.out

# EP-128 / IR-7: named init never inherits another current context or ambient
# target value. A forced re-init reads only its own stored context and keeps its
# backend, while a project change that leaves foreign derived buckets refuses
# before preflight or writes.
mkdir -p "$XDG_CONFIG_HOME/nagare/contexts"
printf '%s\n' \
  'export CLOUDSDK_CORE_PROJECT=other' \
  'export NAGARE_IMAGE_BUCKET=other-nagare-images' \
  'export NAGARE_BACKUP_BUCKET=other-nagare-backups' \
  'export NAGARE_TARGET_PLATFORM=linux/arm64' \
  > "$XDG_CONFIG_HOME/nagare/contexts/foreign.env"
printf '%s\n' foreign > "$XDG_CONFIG_HOME/nagare/current-context"
export NAGARE_IMAGE_BUCKET=ambient-nagare-images
nagarectl init fresh --project p --acme-email ops@example.com \
  --dry-run --skip-preflight > init-fresh.out
grep -q "Derived names for context 'fresh':" init-fresh.out
grep -q 'export NAGARE_IMAGE_BUCKET=p-nagare-images' init-fresh.out
grep -q 'export NAGARE_BACKUP_BUCKET=p-nagare-backups' init-fresh.out
grep -q 'export NAGARE_TARGET_PLATFORM=linux/amd64' init-fresh.out
if grep -q 'other-nagare\|ambient-nagare' init-fresh.out; then
  echo "named init inherited a foreign target value" >&2
  cat init-fresh.out >&2
  exit 1
fi
unset NAGARE_IMAGE_BUCKET

nagarectl context create kept --project p --pulumi-backend gcs
nagarectl init kept --force --acme-email ops@example.com \
  --dry-run --skip-preflight --skip-seed > init-kept.out
grep -q 'export NAGARE_PULUMI_BACKEND=gcs' init-kept.out
grep -q 'export NAGARE_IMAGE_BUCKET=p-nagare-images' init-kept.out
if nagarectl init kept --force --project q --acme-email ops@example.com \
  --dry-run --skip-preflight > init-foreign-project.out 2> init-foreign-project.err; then
  echo "named init accepted stored buckets from another project" >&2
  cat init-foreign-project.out init-foreign-project.err >&2
  exit 1
fi
grep -q 'NAGARE_IMAGE_BUCKET' init-foreign-project.err
grep -q 'NAGARE_BACKUP_BUCKET' init-foreign-project.err
printf '%s\n' local > "$XDG_CONFIG_HOME/nagare/current-context"

# EP-130 / IR-14: tailnet-visible host identity defaults from the context,
# independently of the project-scoped VM instance name. An implicit duplicate
# already present in a sibling host flake is refused, while an explicit choice
# remains the deliberate recovery path.
nagarectl context create prod \
  --mode local \
  --registry-host localhost:5000 \
  --base-domain 127-0-0-1.sslip.io \
  --local-object-store http://minio:9000/nagare-backups
nagarectl context create labs \
  --mode local \
  --registry-host localhost:5000 \
  --base-domain 127-0-0-1.sslip.io \
  --local-object-store http://minio:9000/nagare-backups
printf '%s\n' \
  'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyForNagareEvaluationOnly operator@example' \
  > operator.pub
nagarectl host init --context prod --ssh-public-key-file operator.pub --dry-run > host-prod.out
nagarectl host init --context labs --ssh-public-key-file operator.pub --dry-run > host-labs.out
grep -q '^name: prod-nagare$' host-prod.out
grep -q 'hostName = "prod-nagare";' host-prod.out
grep -q 'instanceName = "nagare-01";' host-prod.out
grep -q '^name: labs-nagare$' host-labs.out
grep -q 'hostName = "labs-nagare";' host-labs.out
grep -q 'instanceName = "nagare-01";' host-labs.out
if grep -q 'labs-nagare' host-prod.out || grep -q 'prod-nagare' host-labs.out; then
  echo "context-derived host names crossed dry-run output" >&2
  exit 1
fi
legacy_host="$XDG_CONFIG_HOME/nagare/hosts/legacy"
mkdir -p "$legacy_host"
printf '%s\n' '{ ... }:' '{' '  nagare.host.hostName = "ignored";' '  hostName = "prod-nagare";' '}' \
  > "$legacy_host/host.nix"
if nagarectl host init --context prod --ssh-public-key-file operator.pub --dry-run \
  > host-collision.out 2> host-collision.err; then
  echo "host init accepted an implicit name already owned by a sibling context" >&2
  exit 1
fi
test ! -s host-collision.out
grep -q "default host name 'prod-nagare' is already used by context 'legacy'" host-collision.err
grep -q "$legacy_host/host.nix" host-collision.err
grep -q -- '--host-name' host-collision.err
nagarectl host init --context prod --host-name prod2-nagare \
  --ssh-public-key-file operator.pub --dry-run > host-explicit.out
grep -q '^name: prod2-nagare$' host-explicit.out

install_fixture_host() {
  local context="$1"
  local host_name="$2"
  local context_file="$XDG_CONFIG_HOME/nagare/contexts/$context.env"
  local host_root="$XDG_CONFIG_HOME/nagare/hosts/$context"
  sed -i '/NAGARE_PLATFORM_VERSION=/d' "$context_file"
  printf '%s\n' 'export NAGARE_PLATFORM_VERSION=0.0.0' >> "$context_file"
  mkdir -p "$host_root"
  printf '%s\n' \
    '{' \
    '  inputs.nagare.url = "path:/old/nagare/nixos";' \
    '  # Generated by nagarectl 0.0.0; EP-108 updates only this input.' \
    '  # Nagare platform version: 0.0.0' \
    '  # Nagare source revision: old' \
    '}' > "$host_root/flake.nix"
  printf '%s\n' '{ ... }:' '{' "  hostName = \"$host_name\";" '}' > "$host_root/host.nix"
  printf '%s\n' 'token: ENC[AES256_GCM,data:test]' 'sops: {}' > "$host_root/secrets.yaml"
}

install_fixture_host prod prod-nagare
install_fixture_host labs labs-nagare
nagarectl host name --context prod > host-prod-name.out
nagarectl host name --context labs --json > host-labs-name.json
grep -q '^prod-nagare$' host-prod-name.out
jq -e '.context == "labs" and .hostName == "labs-nagare"' host-labs-name.json >/dev/null

nagarectl server status --skip-vm > status.out
nagare --list > recipes.out
grep -q 'infra-preview' recipes.out
nagare --dry-run infra-preview --save-plan .tmp/reviewed > recipe-dry-run.out 2>&1
grep -q 'nagarectl infra preview --save-plan .tmp/reviewed' recipe-dry-run.out
nagare --dry-run infra-up --plan .tmp/reviewed --yes > infra-up-dry-run.out 2>&1
grep -q 'nagarectl infra apply --plan .tmp/reviewed --yes' infra-up-dry-run.out
nagare --dry-run iap-ssh recv-file nagare-01 /etc/rancher/k3s/k3s.yaml /tmp/labs.yaml \
  > iap-ssh-dry-run.out 2>&1
grep -q 'scripts/iap-ssh.sh recv-file nagare-01 /etc/rancher/k3s/k3s.yaml /tmp/labs.yaml' \
  iap-ssh-dry-run.out
nagare --dry-run local-smoke > local-smoke-dry-run.out 2>&1
grep -q 'scripts/local-smoke.sh' local-smoke-dry-run.out
# Bootstrap now routes through a retained review and native inventory apply.
nagare --dry-run cluster-bootstrap > cluster-bootstrap-dry-run.out 2>&1
grep -q 'scripts/run-reviewed-bootstrap.sh' cluster-bootstrap-dry-run.out

# EP-134 / IR-20: every cloud recipe that mutates Kubernetes proves the ambient
# kubeconfig belongs to the selected Nagare host before its first write. Local
# recipes deliberately retain their k3d-only preflight.
assert_cluster_guard_before() {
  recipe="$1"
  first_mutation="$2"
  output="${recipe}-guard-order.out"
  nagare --dry-run "$recipe" > "$output" 2>&1
  guard_line="$(grep -n -m1 'nagarectl cluster guard' "$output")"
  mutation_line="$(grep -n -m1 -- "$first_mutation" "$output")"
  guard_number="${guard_line%%:*}"
  mutation_number="${mutation_line%%:*}"
  test "$guard_number" -lt "$mutation_number"
}
grep -q 'nagarectl platform guard' cluster-bootstrap-dry-run.out
assert_cluster_guard_before job-runs-bootstrap 'scripts/run-reviewed-bootstrap.sh'
assert_cluster_guard_before cluster-enable-tls 'kubectl -n knative-serving patch'
assert_cluster_guard_before observability 'scripts/run-reviewed-bootstrap.sh'
assert_cluster_guard_before deploy-hello 'kubectl apply -f cluster/examples/hello-knative-service/service.yaml'
nagare --dry-run local-bootstrap > local-bootstrap-guard-order.out 2>&1
grep -q 'scripts/run-reviewed-bootstrap.sh' local-bootstrap-guard-order.out
nagare --dry-run local-minio > local-minio-guard-order.out 2>&1
grep -q 'scripts/run-reviewed-bootstrap.sh' local-minio-guard-order.out
if grep -q 'nagarectl cluster guard' local-bootstrap-guard-order.out local-minio-guard-order.out; then
  echo "local Kubernetes recipe unexpectedly uses the cloud cluster guard" >&2
  exit 1
fi
grep -q -- '-C.*nagare/local/platform/' "$NAGARE_FAKE_TOOL_LOG"

# A legacy context must be adopted explicitly. The command
# reports observations, stamps the absent cluster marker, and
# commits only this context's release pin.
sed -i '/NAGARE_PLATFORM_VERSION=/d' "$XDG_CONFIG_HOME/nagare/contexts/local.env"
platform_version="$(nagarectl version --json | jq -er '.version')"
nagarectl platform adopt --version "$platform_version" --yes --json > adopt.json
jq -e --arg version "$platform_version" '.adopted == true and .platformVersion == $version and .observations.context == null' adopt.json >/dev/null
grep -q "NAGARE_PLATFORM_VERSION=$platform_version" "$XDG_CONFIG_HOME/nagare/contexts/local.env"

# EP-108: planning from a different context pin stages the host
# release, records all previews, and leaves the context unchanged.
sed -i "s/NAGARE_PLATFORM_VERSION=$platform_version/NAGARE_PLATFORM_VERSION=0.0.0/" "$XDG_CONFIG_HOME/nagare/contexts/local.env"
host_dir="$XDG_CONFIG_HOME/nagare/hosts/local"
mkdir -p "$host_dir"
cat > "$host_dir/flake.nix" <<'HOST_FLAKE'
{
  inputs.nagare.url = "path:/old/nagare/nixos";
  # Generated by nagarectl 0.0.0; EP-108 updates only this input.
  # Nagare platform version: 0.0.0
  # Nagare source revision: old
}
HOST_FLAKE
printf '%s\n' '{ ... }:' '{' '  hostName = "local-nagare";' '}' > "$host_dir/host.nix"
printf '%s\n' 'token: ENC[AES256_GCM,data:test]' 'sops: {}' > "$host_dir/secrets.yaml"
payload_root="$(jq -er '.payloadRoot' root.json)"
nagarectl platform upgrade --to "$platform_version" --payload-root "$payload_root" --dry-run --json > upgrade.json
jq -e --arg version "$platform_version" '.state == "planned" and .previousVersion == "0.0.0" and .targetVersion == $version and ([.phases[] | select(.state == "succeeded")] | length) == 3' upgrade.json >/dev/null
grep -q 'NAGARE_PLATFORM_VERSION=0.0.0' "$XDG_CONFIG_HOME/nagare/contexts/local.env"
local_transaction="$(jq -er '.id' upgrade.json)"
local_kubernetes_bundle="$XDG_STATE_HOME/nagare/local/upgrades/$local_transaction/kubernetes-plan"
test "$(stat -c '%a' "$local_kubernetes_bundle")" = 700
test "$(stat -c '%a' "$local_kubernetes_bundle/config-network.json")" = 600
test "$(stat -c '%a' "$local_kubernetes_bundle/review.json")" = 600
test "$(stat -c '%a' "$local_kubernetes_bundle/metadata.json")" = 600
jq -e '.schemaVersion == 1 and .selectorChange == null and .preserve == [] and .remove == []' \
  "$local_kubernetes_bundle/review.json" >/dev/null
jq -e --arg transaction "$local_transaction" \
  '.schemaVersion == 1 and .transactionId == $transaction and .context == "local"' \
  "$local_kubernetes_bundle/metadata.json" >/dev/null
jq '.tampered = true' "$local_kubernetes_bundle/review.json" > tampered-review.json
install -m 0600 tampered-review.json "$local_kubernetes_bundle/review.json"
if NAGARE_SSH_PUBLIC_KEY_FILE="$PWD/operator.pub" \
  nagarectl platform upgrade --apply --resume "$local_transaction" --yes --json \
  > kubernetes-plan-tampered.out 2> kubernetes-plan-tampered.err; then
  echo "upgrade accepted a tampered Kubernetes migration review" >&2
  exit 1
fi
if ! grep -q 'review.json digest does not match metadata.json' kubernetes-plan-tampered.err; then
  cat kubernetes-plan-tampered.out kubernetes-plan-tampered.err >&2
  exit 1
fi
grep -q 'NAGARE_PLATFORM_VERSION=0.0.0' "$XDG_CONFIG_HOME/nagare/contexts/local.env"

# BUG-2 / EP-141: the upgrade owns all logical host identity passed to the
# guarded switch. Both contexts retain the GCE instance name nagare-01, an
# ambient sibling identity tries to redirect the labs transaction, and the
# recording transports prove every Nix/SSH operation stays on labs-nagare.
legacy_kube_state="$PWD/legacy-kube-state"
mkdir -p "$legacy_kube_state"
NAGARE_FAKE_LEGACY_CERTS=1 \
  NAGARE_FAKE_KUBE_STATE="$legacy_kube_state" \
  nagarectl --context labs platform upgrade \
  --to "$platform_version" --payload-root "$payload_root" --dry-run --json \
  > labs-upgrade.json
labs_transaction="$(jq -er '.id' labs-upgrade.json)"
labs_kubernetes_bundle="$XDG_STATE_HOME/nagare/labs/upgrades/$labs_transaction/kubernetes-plan"
test -f "$labs_kubernetes_bundle/review.json"
jq -e '
  .selectorChange.from == "{}" and
  .selectorChange.to == "matchLabels:\n  nagare.dev/app-namespace: \"true\"\n" and
  ([.preserve[].knativeCertificate.namespace] == ["personal"]) and
  ([.remove[].knativeCertificate.namespace] == ["kube-system", "observability"]) and
  ([.remove[].generatedSecret.name] == ["kube-system-wildcard-tls", "observability-wildcard-tls"])
' "$labs_kubernetes_bundle/review.json" >/dev/null
test ! -e "$legacy_kube_state/selector-applied"
test ! -e "$legacy_kube_state/secret-kube-system"
test ! -e "$legacy_kube_state/secret-observability"
mkdir -p apply-bin
printf '%s\n' \
  "#!$BASH" \
  'printf "just %s\n" "$*" >> "${NAGARE_FAKE_TOOL_LOG:?}"' \
  > apply-bin/just
chmod +x apply-bin/just
: > "$NAGARE_FAKE_TOOL_LOG"
PATH="$PWD/apply-bin:$PATH" \
  NAGARE_FAKE_LEGACY_CERTS=1 \
  NAGARE_FAKE_KUBE_STATE="$legacy_kube_state" \
  NAGARE_HOST_ATTR=prod-nagare \
  NAGARE_SSH_HOST=prod-nagare \
  NAGARE_SSH_PUBLIC_KEY_FILE="$PWD/operator.pub" \
  nagarectl --context labs platform upgrade \
    --apply --resume "$labs_transaction" --yes --json > labs-applied.json
jq -e --arg version "$platform_version" '.state == "completed" and .targetVersion == $version' \
  labs-applied.json >/dev/null
test -e "$legacy_kube_state/selector-applied"
test -e "$legacy_kube_state/knative-cleaned"
test -e "$legacy_kube_state/managers-cleaned"
test -e "$legacy_kube_state/secret-kube-system"
test -e "$legacy_kube_state/secret-observability"
grep -q '^kubectl apply --server-side --force-conflicts --field-manager=nagare-upgrade -f -$' "$NAGARE_FAKE_TOOL_LOG"
grep -q '^kubectl delete secret kube-system-wildcard-tls -n kube-system --wait=true$' "$NAGARE_FAKE_TOOL_LOG"
grep -q '^kubectl delete secret observability-wildcard-tls -n observability --wait=true$' "$NAGARE_FAKE_TOOL_LOG"
selector_line="$(grep -n -m1 '^kubectl apply --server-side' "$NAGARE_FAKE_TOOL_LOG" | cut -d: -f1)"
bootstrap_line="$(grep -n -m1 '^just ' "$NAGARE_FAKE_TOOL_LOG" | cut -d: -f1)"
test "$selector_line" -lt "$bootstrap_line"
grep -q 'nixosConfigurations.labs-nagare' "$NAGARE_FAKE_TOOL_LOG"
grep -q '^ssh .*deploy@labs-nagare' "$NAGARE_FAKE_TOOL_LOG"
if grep -q 'nixosConfigurations.nagare-01\|deploy@nagare-01\|nixosConfigurations.prod-nagare\|deploy@prod-nagare' \
  "$NAGARE_FAKE_TOOL_LOG"; then
  echo "labs upgrade addressed the GCE instance or sibling logical host" >&2
  cat "$NAGARE_FAKE_TOOL_LOG" >&2
  exit 1
fi
grep -q "Nagare platform version: $platform_version" "$XDG_CONFIG_HOME/nagare/hosts/labs/flake.nix"
grep -q 'Nagare platform version: 0.0.0' "$XDG_CONFIG_HOME/nagare/hosts/prod/flake.nix"

# A completed transaction is a fixed point: reapplying it performs no
# Kubernetes mutation and does not invoke bootstrap again.
mutation_count="$(grep -Ec '^kubectl (apply --server-side|delete secret)|^just ' "$NAGARE_FAKE_TOOL_LOG")"
PATH="$PWD/apply-bin:$PATH" \
  NAGARE_FAKE_LEGACY_CERTS=1 \
  NAGARE_FAKE_KUBE_STATE="$legacy_kube_state" \
  NAGARE_HOST_ATTR=prod-nagare \
  NAGARE_SSH_HOST=prod-nagare \
  NAGARE_SSH_PUBLIC_KEY_FILE="$PWD/operator.pub" \
  nagarectl --context labs platform upgrade \
    --apply --resume "$labs_transaction" --yes --json > labs-reapplied.json
jq -e '.state == "completed"' labs-reapplied.json >/dev/null
test "$(grep -Ec '^kubectl (apply --server-side|delete secret)|^just ' "$NAGARE_FAKE_TOOL_LOG")" = "$mutation_count"

# BUG-4 / EP-143: Pulumi success is a private, transaction-bound receipt. A
# started receipt refuses a normal resume without touching Pulumi; an explicit
# applied recovery lets later phases resume provider-free. A legacy successful
# journal with no receipt also refuses, while an explicit retry authorization
# is consumed by exactly one retained-plan apply.
labs_transaction_path="$XDG_STATE_HOME/nagare/labs/upgrades/$labs_transaction.json"
labs_receipt="$XDG_STATE_HOME/nagare/labs/upgrades/$labs_transaction/pulumi-apply-receipt.json"
test "$(stat -c '%a' "$labs_receipt")" = 600
jq -e --arg transaction "$labs_transaction" \
  '.schemaVersion == 1 and .state == "succeeded" and .transactionId == $transaction' \
  "$labs_receipt" >/dev/null
test "$(grep -c 'pulumi .* up --plan ' "$NAGARE_FAKE_TOOL_LOG")" = 1

jq '(.phases[] | select(.name == "pulumi-apply" or .name == "host-apply")) |= (.state = "pending" | .evidence = null) | .state = "failed"' \
  "$labs_transaction_path" > transaction-started.json
install -m 0600 transaction-started.json "$labs_transaction_path"
jq '.state = "started" | .recoveryOutcome = null' "$labs_receipt" > receipt-started.json
install -m 0600 receipt-started.json "$labs_receipt"
: > "$NAGARE_FAKE_TOOL_LOG"
if NAGARE_SSH_PUBLIC_KEY_FILE="$PWD/operator.pub" \
  nagarectl --context labs platform upgrade --apply --resume "$labs_transaction" --yes \
    > pulumi-ambiguous.out 2> pulumi-ambiguous.err; then
  echo "ambiguous Pulumi receipt was accepted by normal resume" >&2
  exit 1
fi
grep -q 'recover-pulumi' pulumi-ambiguous.err
test "$(grep -c '^pulumi ' "$NAGARE_FAKE_TOOL_LOG" || true)" = 0

nagarectl --context labs platform upgrade recover-pulumi "$labs_transaction" \
  --outcome applied --yes > pulumi-recovered-applied.out
jq -e '.state == "operator-attested" and .recoveryOutcome == "applied"' "$labs_receipt" >/dev/null
mkdir -p resume-bin
printf '%s\n' \
  "#!$BASH" \
  'printf "ssh %s\n" "$*" >> "${NAGARE_FAKE_TOOL_LOG:?}"' \
  'exit 88' \
  > resume-bin/ssh
chmod +x resume-bin/ssh
: > "$NAGARE_FAKE_TOOL_LOG"
if PATH="$PWD/resume-bin:$PWD/apply-bin:$PATH" \
  NAGARE_FAKE_LEGACY_CERTS=1 \
  NAGARE_FAKE_KUBE_STATE="$legacy_kube_state" \
  NAGARE_SSH_PUBLIC_KEY_FILE="$PWD/operator.pub" \
  nagarectl --context labs platform upgrade \
    --apply --resume "$labs_transaction" --yes --json \
    > pulumi-recovered-applied.json 2> pulumi-recovered-applied.err; then
  echo "injected host failure unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'host-apply failed' pulumi-recovered-applied.err
test "$(grep -c '^pulumi ' "$NAGARE_FAKE_TOOL_LOG" || true)" = 0

rm "$labs_receipt"
jq '(.phases[] | select(.name == "pulumi-apply")) |= (.state = "succeeded" | .evidence = "legacy success") | .state = "failed"' \
  "$labs_transaction_path" > transaction-legacy.json
install -m 0600 transaction-legacy.json "$labs_transaction_path"
: > "$NAGARE_FAKE_TOOL_LOG"
if NAGARE_SSH_PUBLIC_KEY_FILE="$PWD/operator.pub" \
  nagarectl --context labs platform upgrade --apply --resume "$labs_transaction" --yes \
    > pulumi-legacy.out 2> pulumi-legacy.err; then
  echo "legacy Pulumi success without a receipt was accepted by normal resume" >&2
  exit 1
fi
grep -q 'predates durable receipts' pulumi-legacy.err
test "$(grep -c '^pulumi ' "$NAGARE_FAKE_TOOL_LOG" || true)" = 0

nagarectl --context labs platform upgrade recover-pulumi "$labs_transaction" \
  --outcome retry --yes > pulumi-recovered-retry.out
jq -e '.state == "operator-attested" and .recoveryOutcome == "retry"' "$labs_receipt" >/dev/null
: > "$NAGARE_FAKE_TOOL_LOG"
if PATH="$PWD/resume-bin:$PWD/apply-bin:$PATH" \
  NAGARE_FAKE_LEGACY_CERTS=1 \
  NAGARE_FAKE_KUBE_STATE="$legacy_kube_state" \
  NAGARE_SSH_PUBLIC_KEY_FILE="$PWD/operator.pub" \
  nagarectl --context labs platform upgrade \
    --apply --resume "$labs_transaction" --yes --json \
    > pulumi-recovered-retry.json 2> pulumi-recovered-retry.err; then
  echo "injected host failure unexpectedly succeeded after Pulumi retry" >&2
  exit 1
fi
grep -q 'host-apply failed' pulumi-recovered-retry.err
test "$(grep -c 'pulumi .* up --plan ' "$NAGARE_FAKE_TOOL_LOG")" = 1
jq -e '.state == "succeeded" and .recoveryOutcome == null' "$labs_receipt" >/dev/null

# An ambiguous context-owned module is copied into staging, then rejected by
# the shared validated parser before the transaction can evaluate or contact a
# host. The selected context is present in the diagnostic.
nagarectl context create ambiguous \
  --mode local \
  --registry-host localhost:5000 \
  --base-domain 127-0-0-1.sslip.io \
  --local-object-store http://minio:9000/nagare-backups
install_fixture_host ambiguous ambiguous-nagare
printf '%s\n' \
  '{ ... }:' '{' \
  '  hostName = "ambiguous-nagare";' \
  '  hostName = "nagare-01";' \
  '}' > "$XDG_CONFIG_HOME/nagare/hosts/ambiguous/host.nix"
: > "$NAGARE_FAKE_TOOL_LOG"
if nagarectl --context ambiguous platform upgrade \
  --to "$platform_version" --payload-root "$payload_root" --dry-run --json \
  > ambiguous-upgrade.out 2> ambiguous-upgrade.err; then
  echo "platform upgrade accepted an ambiguous generated host identity" >&2
  exit 1
fi
test ! -s ambiguous-upgrade.out
grep -q "context 'ambiguous' declares hostName more than once" ambiguous-upgrade.err
if grep -q 'nixosConfigurations\|^ssh ' "$NAGARE_FAKE_TOOL_LOG"; then
  echo "ambiguous host identity reached host evaluation or transport" >&2
  cat "$NAGARE_FAKE_TOOL_LOG" >&2
  exit 1
fi

# EP-113: `nagarectl context guard` refuses when the selected Pulumi
# stack's gcp:project disagrees with the active context. This is the
# preflight `just infra-up` / `just infra-preview` now run before
# Pulumi is invoked at all. The ambient CLOUDSDK_CORE_PROJECT is set
# to the context's own project so the guard's third source (gcloud's
# configured project, which the fake gcloud answers with JSON) is not
# consulted; the stack alone varies between the two runs.
nagarectl context create guardcloud \
  --project acme-prod \
  --region us-west1 \
  --zone us-west1-a \
  --base-domain apps.acme.example
export CLOUDSDK_CORE_PROJECT=acme-prod
mkdir -p "$HOME/.config/gcloud"
printf '%s\n' \
  '{"type":"authorized_user","client_id":"fixture","client_secret":"never-print-this","refresh_token":"never-print-this-either","quota_project_id":"acme-prod"}' \
  > "$HOME/.config/gcloud/application_default_credentials.json"

NAGARE_FAKE_STACK_PROJECT=acme-prod \
  nagarectl --context guardcloud context guard > guard-ok.out 2> guard-ok.err
grep -q 'context guard: guardcloud confined to project acme-prod (stack guardcloud)' guard-ok.out

if NAGARE_FAKE_STACK_PROJECT=some-other-project \
  nagarectl --context guardcloud context guard > guard-bad.out 2> guard-bad.err; then
  echo "context guard accepted a stack targeting a foreign project" >&2
  cat guard-bad.out guard-bad.err >&2
  exit 1
fi
grep -q 'some-other-project' guard-bad.err
grep -q 'acme-prod' guard-bad.err
grep -q 'guardcloud' guard-bad.err
grep -q 'file://' guard-bad.err

if NAGARE_FAKE_PULUMI_CONFIG_RESULT=missing \
  nagarectl --context guardcloud context guard > guard-missing.out 2> guard-missing.err; then
  echo "context guard accepted a stack without gcp:project" >&2
  exit 1
fi
grep -q 'declares no gcp:project' guard-missing.err
grep -q 'nagarectl context use guardcloud' guard-missing.err

if NAGARE_FAKE_PULUMI_CONFIG_RESULT=failed \
  nagarectl --context guardcloud context guard > guard-failed.out 2> guard-failed.err; then
  echo "context guard accepted a failed Pulumi config probe" >&2
  exit 1
fi
grep -q 'exited with status 23' guard-failed.err
grep -q 'error: could not access backend: test authentication failure' guard-failed.err
if grep -q 'declares no gcp:project\|nagarectl context use' guard-failed.err; then
  echo "context guard misdiagnosed a failed Pulumi command as an absent project" >&2
  exit 1
fi

if NAGARE_FAKE_STACK_PROJECT=some-other-project \
  nagarectl --context guardcloud context guard --json > guard-bad-json.out 2> guard-bad.json; then
  echo "context guard JSON accepted a stack targeting a foreign project" >&2
  exit 1
fi
test ! -s guard-bad-json.out
jq -e '
  .confined == false and
  .observations.stack == "guardcloud" and
  (.observations.pulumiBackendUrl | startswith("file://")) and
  .observations.stackProject == "some-other-project" and
  .observations.stackProjectProbe.status == "found" and
  .observations.adc.status == "found" and
  .observations.adc.quotaProject == "acme-prod" and
  (.observations.warnings | type == "array")
' guard-bad.json >/dev/null

# EP-135: a foreign ADC quota project is rejected before workspace preparation
# can invoke Pulumi. The refusal names the exact repair and never prints tokens.
pulumi_calls_before="$(grep -c '^pulumi ' "$NAGARE_FAKE_TOOL_LOG" || true)"
printf '%s\n' \
  '{"type":"authorized_user","client_id":"fixture","client_secret":"secret-sentinel","refresh_token":"refresh-sentinel","quota_project_id":"foreign-prod"}' \
  > "$HOME/.config/gcloud/application_default_credentials.json"
if NAGARE_FAKE_STACK_PROJECT=acme-prod \
  nagarectl --context guardcloud context guard > guard-adc.out 2> guard-adc.err; then
  echo "context guard accepted a foreign ADC quota project" >&2
  exit 1
fi
pulumi_calls_after="$(grep -c '^pulumi ' "$NAGARE_FAKE_TOOL_LOG" || true)"
test "$pulumi_calls_after" = "$pulumi_calls_before"
grep -q 'foreign-prod' guard-adc.err
grep -q 'application-default set-quota-project acme-prod' guard-adc.err
if grep -q 'secret-sentinel\|refresh-sentinel' guard-adc.err; then
  echo "context guard exposed ADC credential material" >&2
  exit 1
fi
printf '%s\n' \
  '{"type":"authorized_user","client_id":"fixture","client_secret":"never-print-this","refresh_token":"never-print-this-either","quota_project_id":"acme-prod"}' \
  > "$HOME/.config/gcloud/application_default_credentials.json"

# EP-135 / IR-16: NotFound is authoritative undeployed evidence, status keeps
# patch skew visible, and re-pin becomes permanently unavailable once a VM
# exists or the lookup is inconclusive.
context_file="$XDG_CONFIG_HOME/nagare/contexts/guardcloud.env"
platform_major_minor="${platform_version%.*}"
platform_patch="${platform_version##*.}"
patch_skew_version="$platform_major_minor.$((platform_patch + 1))"
sed -i "s/^export NAGARE_PLATFORM_VERSION=.*/export NAGARE_PLATFORM_VERSION=$patch_skew_version/" "$context_file"
guard_host="$XDG_CONFIG_HOME/nagare/hosts/guardcloud"
mkdir -p "$guard_host"
printf '%s\n' \
  '{' \
  "  # Generated by nagarectl $patch_skew_version; EP-108 updates only this input." \
  "  # Nagare platform version: $patch_skew_version" \
  '  # Nagare source revision: old' \
  '  inputs.nagare.url = "path:/old/nagare/nixos";' \
  '}' > "$guard_host/flake.nix"
printf '%s\n' '{ ... }: { nagare.host.hostName = "guardcloud-nagare"; }' > "$guard_host/host.nix"
printf '%s\n' 'token: ENC[AES256_GCM,data:preserved]' 'sops: {}' > "$guard_host/secrets.yaml"
host_module_before="$(cat "$guard_host/host.nix")"
host_secrets_before="$(cat "$guard_host/secrets.yaml")"
NAGARE_FAKE_GCE_DESCRIBE_RESULT=not-found \
  nagarectl --context guardcloud platform status --json > undeployed-status.json
jq -e '
  .compatibility == "patch-skew" and
  .deployment.host.state == "not-deployed" and
  .deployment.cluster.state == "not-deployed"
' undeployed-status.json >/dev/null
NAGARE_FAKE_GCE_DESCRIBE_RESULT=not-found NAGARE_FAKE_STACK_PROJECT=acme-prod \
  nagarectl --context guardcloud platform repin --version "$platform_version" --yes > repin.out
grep -q 'Host:.*not deployed' repin.out
grep -q 'Cluster:.*not deployed' repin.out
grep -q "re-pinned context 'guardcloud' to Nagare platform $platform_version" repin.out
grep -q "NAGARE_PLATFORM_VERSION=$platform_version" "$context_file"
grep -q "Nagare platform version: $platform_version" "$guard_host/flake.nix"
test "$(cat "$guard_host/host.nix")" = "$host_module_before"
test "$(cat "$guard_host/secrets.yaml")" = "$host_secrets_before"

if NAGARE_FAKE_GCE_DESCRIBE_RESULT=exists NAGARE_FAKE_STACK_PROJECT=acme-prod \
  nagarectl --context guardcloud platform repin --version "$platform_version" --yes > repin-existing.out 2> repin-existing.err; then
  echo "platform re-pin accepted an existing GCE instance" >&2
  exit 1
fi
grep -q "GCE instance exists or its absence could not be proven" repin-existing.err

for lookup_result in failed network malformed; do
  if NAGARE_FAKE_GCE_DESCRIBE_RESULT="$lookup_result" NAGARE_FAKE_STACK_PROJECT=acme-prod \
    nagarectl --context guardcloud platform repin --version "$platform_version" --yes > "repin-$lookup_result.out" 2> "repin-$lookup_result.err"; then
    echo "platform re-pin accepted an inconclusive GCE lookup: $lookup_result" >&2
    exit 1
  fi
  grep -q "GCE instance exists or its absence could not be proven" "repin-$lookup_result.err"
done
grep -q "NAGARE_PLATFORM_VERSION=$platform_version" "$context_file"

# EP-121: the stack config is context-owned. Every Pulumi-running command links
# the workspace's Pulumi.<context>.yaml to the canonical XDG file, adopts a
# pre-0.2.1 workspace copy when no canonical file exists, and refuses rather
# than choose between two different copies or read a dangling link as empty.
canonical="$XDG_CONFIG_HOME/nagare/pulumi/Pulumi.guardcloud.yaml"
guard_workspace="$(nagarectl --context guardcloud platform root --json | jq -er '.workspaceRoot')"
entry="$guard_workspace/infra/pulumi/Pulumi.guardcloud.yaml"
test -f "$canonical"
test -L "$entry"
test "$(readlink "$entry")" = "$canonical"
test "$(grep -c "npm ci --no-audit --no-fund in $guard_workspace/infra/pulumi" "$NAGARE_FAKE_TOOL_LOG")" = 1

rm "$entry" "$canonical"
printf 'config:\n  nagare:legacy: kept\n' > "$entry"
NAGARE_FAKE_STACK_PROJECT=acme-prod nagarectl --context guardcloud context guard > /dev/null
test -L "$entry"
grep -q 'nagare:legacy: kept' "$canonical"

rm "$entry"
printf 'config:\n  nagare:legacy: different\n' > "$entry"
if NAGARE_FAKE_STACK_PROJECT=acme-prod \
  nagarectl --context guardcloud context guard > link-conflict.out 2> link-conflict.err; then
  echo "context guard accepted a workspace stack config that differs from the canonical one" >&2
  exit 1
fi
grep -q 'differs from the context-owned stack config' link-conflict.err
grep -q 'nagare:legacy: kept' "$canonical"

# EP-136 / IR-15: one fake Pulumi preview writes both the Pulumi deployment
# plan and Nagare's redacted review. Apply verifies every binding and invokes
# only `pulumi up --plan ... --yes --non-interactive`; it never launches a
# second preview process.
rm "$entry"
ln -s "$canonical" "$entry"
reviewed_bundle="$PWD/guardcloud-reviewed-plan"
preview_calls_before="$(grep -c 'pulumi .* preview ' "$NAGARE_FAKE_TOOL_LOG" || true)"
NAGARE_FAKE_STACK_PROJECT=acme-prod \
  nagarectl --context guardcloud infra preview --save-plan "$reviewed_bundle" > saved-preview.out
preview_calls_after="$(grep -c 'pulumi .* preview ' "$NAGARE_FAKE_TOOL_LOG" || true)"
test "$preview_calls_after" = "$(( preview_calls_before + 1 ))"
test "$(stat -c '%a' "$reviewed_bundle")" = 700
test "$(stat -c '%a' "$reviewed_bundle/pulumi-plan.json")" = 600
test "$(stat -c '%a' "$reviewed_bundle/review.json")" = 600
test "$(stat -c '%a' "$reviewed_bundle/metadata.json")" = 600
jq -e '.schemaVersion == 1 and .replacementApproved == false and .verdict == "allowed"' \
  "$reviewed_bundle/review.json" >/dev/null
jq -e '.context == "guardcloud" and .project == "acme-prod" and .pulumiVersion == "v3.255.0"' \
  "$reviewed_bundle/metadata.json" >/dev/null

NAGARE_FAKE_STACK_PROJECT=acme-prod \
  nagarectl --context guardcloud infra apply --plan "$reviewed_bundle" --yes > saved-apply.out
grep -q "pulumi .* up --plan $reviewed_bundle/pulumi-plan.json --stack guardcloud --yes --non-interactive" \
  "$NAGARE_FAKE_TOOL_LOG"
test "$(grep -c 'pulumi .* preview ' "$NAGARE_FAKE_TOOL_LOG" || true)" = "$preview_calls_after"

nagarectl context create guardother \
  --project acme-prod \
  --region us-west1 \
  --zone us-west1-a \
  --base-domain other.acme.example
if NAGARE_FAKE_STACK_PROJECT=acme-prod \
  nagarectl --context guardother infra apply --plan "$reviewed_bundle" --yes \
    > saved-other.out 2> saved-other.err; then
  echo "saved plan from another context was accepted" >&2
  exit 1
fi
grep -q "saved plan context is 'guardcloud', but the current value is 'guardother'" saved-other.err

printf '%s\n' tampered >> "$reviewed_bundle/pulumi-plan.json"
if NAGARE_FAKE_STACK_PROJECT=acme-prod \
  nagarectl --context guardcloud infra apply --plan "$reviewed_bundle" --yes \
    > saved-tampered.out 2> saved-tampered.err; then
  echo "tampered Pulumi plan was accepted" >&2
  exit 1
fi
grep -q 'pulumi-plan.json digest does not match' saved-tampered.err

rm "$entry" "$canonical"
ln -s "$XDG_CONFIG_HOME/nagare/operator-repo/missing.yaml" "$canonical"
if NAGARE_FAKE_STACK_PROJECT=acme-prod \
  nagarectl --context guardcloud context guard > link-dangling.out 2> link-dangling.err; then
  echo "context guard accepted a dangling context-owned stack config" >&2
  exit 1
fi
grep -q 'is a symlink to missing' link-dangling.err
unset CLOUDSDK_CORE_PROJECT

touch "$out"
