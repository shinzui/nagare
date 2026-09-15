#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/rehearse-clone-free-release.sh --version VERSION [--flake-ref REF] [--output FILE]

Exercise a versioned Nagare flake from an isolated home and a directory outside its source checkout.
When --flake-ref is omitted, the current clean HEAD is consumed through an exact git+file revision.
EOF
}

die() {
  printf 'nagare clone-free rehearsal: %s\n' "$*" >&2
  exit 1
}

version=""
flake_ref=""
output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      version="$2"
      shift 2
      ;;
    --flake-ref)
      [[ $# -ge 2 ]] || die "--flake-ref requires a value"
      flake_ref="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a value"
      output="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || die "--version must be an unpadded major.minor.patch semantic version"
command -v git >/dev/null 2>&1 || die "git is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v nix >/dev/null 2>&1 || die "Nix with flakes is required"

repo_root="$(git rev-parse --show-toplevel)"
revision="$(git -C "$repo_root" rev-parse HEAD)"
if [[ -z "$flake_ref" ]]; then
  [[ -z "$(git -C "$repo_root" status --porcelain)" ]] \
    || die "the default exact-commit rehearsal requires a clean worktree"
  flake_ref="git+file://${repo_root}?rev=${revision}"
fi

test_root="$(mktemp -d "${TMPDIR:-/tmp}/nagare-clone-free.XXXXXX")"
cleanup() {
  local attempt
  for attempt in 1 2 3 4 5; do
    rm -rf -- "$test_root" 2>/dev/null && return 0
    sleep 1
  done
  rm -rf -- "$test_root"
}
trap cleanup EXIT
mkdir -p "$test_root/home" "$test_root/config" "$test_root/state" "$test_root/work"
cp "$repo_root/cluster/examples/hello-knative-service/nagare/Config.hs" "$test_root/work/Config.hs"
cp "$repo_root/cli/nagarectl/test/fixtures/operator.pub" "$test_root/work/operator.pub"

# A shell entered through .envrc exports the operator's active context. Drop it so the
# rehearsal sees only the isolated XDG tree, as a clean CI runner does.
for name in ${!NAGARE_@} ${!CLOUDSDK_@} ${!PULUMI_@}; do
  unset "$name"
done

export HOME="$test_root/home"
export XDG_CONFIG_HOME="$test_root/config"
export XDG_STATE_HOME="$test_root/state"
cd "$test_root/work"

run_cli() {
  nix run "${flake_ref}#nagarectl" -- "$@"
}

run_operator() {
  nix run "${flake_ref}#nagare" -- "$@"
}

run_target_operator_cli() {
  nix shell "${flake_ref}#nagare" -c nagarectl "$@"
}

run_cli version --json > version.json
jq -e --arg version "$version" '.version == $version and (.revision | length > 0)' version.json >/dev/null
nix shell "${flake_ref}#nagare" -c nagarectl version --json > operator-version.json
jq -e --arg version "$version" --arg revision "$(jq -er '.revision' version.json)" \
  '.version == $version and .revision == $revision' operator-version.json >/dev/null

# The documented clone-free operator command must supply Pulumi itself. Build a PATH containing
# only the host tools needed to enter the Nix shell so an installed Pulumi cannot leak into this
# proof, then inspect and execute the tools selected by the target release.
isolated_host_bin="$test_root/host-tools"
mkdir -p "$isolated_host_bin"
for tool in bash git mkdir nix; do
  tool_path="$(command -v "$tool")"
  ln -s "$tool_path" "$isolated_host_bin/$tool"
done
if PATH="$isolated_host_bin" command -v pulumi >/dev/null 2>&1; then
  die "isolated host PATH unexpectedly contains pulumi"
fi
if PATH="$isolated_host_bin" command -v pulumi-language-nodejs >/dev/null 2>&1; then
  die "isolated host PATH unexpectedly contains pulumi-language-nodejs"
fi
PATH="$isolated_host_bin" run_target_operator_cli version --json --tools > operator-tools.json
jq -e '
  (.tools.pulumi | startswith("/nix/store/")) and
  (.tools["pulumi-language-nodejs"] | startswith("/nix/store/"))
' operator-tools.json >/dev/null
operator_pulumi="$(jq -er '.tools.pulumi' operator-tools.json)"
"$operator_pulumi" version > pulumi-version.out
grep -q '^v3\.255\.0$' pulumi-version.out

run_cli context create local --mode local \
  --registry-host localhost:5000 \
  --base-domain 127-0-0-1.sslip.io \
  --local-object-store http://minio:9000/nagare-backups \
  --use
run_cli context show local > local-context.env
run_cli deploy --dry-run --file "$test_root/work/Config.hs" > typed-config.out
run_cli platform root --json > platform-root.json
jq -e --arg version "$version" \
  '.source == "installed" and .platformVersion == $version and (.workspaceRoot | length > 0)' \
  platform-root.json >/dev/null
workspace_root="$(jq -er '.workspaceRoot' platform-root.json)"
test -f "$workspace_root/cli/nagare-dsl/nagare-dsl.cabal"
test -f "$workspace_root/cli/nagare-access/nagare-access.cabal"
test -f "$workspace_root/cli/nagare-access/Dockerfile"
# shellcheck source=scripts/lib/release.sh
source "$workspace_root/scripts/lib/release.sh"
expected_source_tag="$(jq -er '.revision' version.json | cut -c1-12)"
[[ "$(nagare_release_source_tag "$workspace_root")" == "$expected_source_tag" ]]
run_operator --dry-run local-up > local-init.out 2>&1

# Exercise the exact operator command shape from docs/user/upgrades.md. The doubles are deliberately
# earlier on PATH than the wrapper's release-pinned fallbacks, so the rehearsal records a safe plan
# without contacting Nix builders, Pulumi backends, clouds, hosts, or Kubernetes clusters.
local_context="$XDG_CONFIG_HOME/nagare/contexts/local.env"
local_context_tmp="$local_context.tmp"
while IFS= read -r line; do
  if [[ "$line" == export\ NAGARE_PLATFORM_VERSION=* ]]; then
    printf '%s\n' 'export NAGARE_PLATFORM_VERSION=0.0.0'
  else
    printf '%s\n' "$line"
  fi
done < "$local_context" > "$local_context_tmp"
mv "$local_context_tmp" "$local_context"

local_host="$XDG_CONFIG_HOME/nagare/hosts/local"
mkdir -p "$local_host"
cat > "$local_host/flake.nix" <<'HOST_FLAKE'
{
  inputs.nagare.url = "path:/old/nagare/nixos";
  # Generated by nagarectl 0.0.0; EP-108 updates only this input.
  # Nagare platform version: 0.0.0
  # Nagare source revision: old
}
HOST_FLAKE
printf '%s\n' '{ ... }: { }' > "$local_host/host.nix"
printf '%s\n' 'token: ENC[AES256_GCM,data:test]' 'sops: {}' > "$local_host/secrets.yaml"

fake_tools="$test_root/upgrade-tools"
upgrade_tool_log="$test_root/upgrade-tools.log"
mkdir -p "$fake_tools"
: > "$upgrade_tool_log"
cat > "$fake_tools/pulumi" <<'FAKE_PULUMI'
#!/usr/bin/env bash
printf 'pulumi %s\n' "$*" >> "${NAGARE_FAKE_TOOL_LOG:?}"
case " $* " in
  " version ")
    printf '%s\n' 'v3.255.0'
    ;;
  *" config --json "*)
    printf '%s\n' '{}'
    ;;
  *" preview --json --save-plan "*)
    previous=""
    for argument in "$@"; do
      if [[ "$previous" == "--save-plan" ]]; then
        printf '%s\n' '{"version":1,"resourcePlans":{}}' > "$argument"
        break
      fi
      previous="$argument"
    done
    printf '%s\n' '{"steps":[]}'
    ;;
esac
FAKE_PULUMI
cat > "$fake_tools/npm" <<'FAKE_NPM'
#!/usr/bin/env bash
printf 'npm %s in %s\n' "$*" "$PWD" >> "${NAGARE_FAKE_TOOL_LOG:?}"
mkdir -p node_modules/@pulumi/pulumi
printf '%s\n' '{}' > node_modules/@pulumi/pulumi/package.json
FAKE_NPM
cat > "$fake_tools/nix" <<'FAKE_NIX'
#!/usr/bin/env bash
if [[ "${1:-}" == "shell" ]]; then
  exec "${NAGARE_REAL_NIX:?}" "$@"
fi
printf 'nix %s\n' "$*" >> "${NAGARE_FAKE_TOOL_LOG:?}"
printf '%s\n' '/nix/store/fake-nagare-upgrade-result'
FAKE_NIX
for tool in gcloud kubectl; do
  cat > "$fake_tools/$tool" <<FAKE_TOOL
#!/usr/bin/env bash
printf '$tool %s\\n' "\$*" >> "\${NAGARE_FAKE_TOOL_LOG:?}"
printf '%s\\n' '{"items":[]}'
FAKE_TOOL
done
chmod +x "$fake_tools"/*

real_nix="$(command -v nix)"
PATH="$fake_tools:$isolated_host_bin" \
NAGARE_REAL_NIX="$real_nix" \
NAGARE_FAKE_TOOL_LOG="$upgrade_tool_log" \
  run_target_operator_cli platform upgrade --to "$version" --dry-run --json > target-upgrade.json
jq -e --arg version "$version" '
  .state == "planned" and
  .previousVersion == "0.0.0" and
  .targetVersion == $version and
  ([.phases[] | select(.name == "nix-evaluate" or .name == "pulumi-preview" or .name == "kubernetes-diff") | select(.state == "succeeded")] | length) == 3 and
  ([.phases[] | select(.name == "pulumi-apply" or .name == "host-apply" or .name == "kubernetes-apply" or .name == "cluster-stamp" or .name == "context-commit") | select(.state == "pending")] | length) == 5
' target-upgrade.json >/dev/null
upgrade_id="$(jq -er '.id' target-upgrade.json)"
reviewed_bundle="$XDG_STATE_HOME/nagare/local/upgrades/$upgrade_id/pulumi-plan"
test -s "$reviewed_bundle/pulumi-plan.json"
test -s "$reviewed_bundle/review.json"
test -s "$reviewed_bundle/metadata.json"
grep -q '^nix eval path:.*#packages\.x86_64-linux\.nagare-image\.drvPath$' "$upgrade_tool_log"
test "$(grep -c 'pulumi .* preview --json --save-plan ' "$upgrade_tool_log")" = 1
grep -q '^kubectl diff -f - --request-timeout=5s$' "$upgrade_tool_log"
if grep -q 'pulumi .* up \|host-switch\.sh\|kubectl apply\|^gcloud ' "$upgrade_tool_log"; then
  die "clone-free upgrade plan reached a mutation or cloud command"
fi
grep -q 'NAGARE_PLATFORM_VERSION=0.0.0' "$local_context"

run_cli context create rehearsal-cloud \
  --project nagare-release-rehearsal \
  --region us-west1 \
  --zone us-west1-a \
  --base-domain rehearsal.example.com
export NAGARE_CONTEXT=rehearsal-cloud
run_cli init cloud-onboarding \
  --project nagare-release-rehearsal \
  --base-domain rehearsal.example.com \
  --acme-email ops@rehearsal.example.com \
  --skip-preflight --skip-enable --skip-seed --dry-run > cloud-init.out
run_cli host init --context rehearsal-cloud \
  --ssh-public-key-file "$test_root/work/operator.pub" --dry-run > host-init.out
# EP-113: a clone-free recipe run must carry the ACTIVE CONTEXT's Pulumi backend
# and stack, exactly as a direnv-loaded checkout does. There is no .envrc in an
# installed operator's shell, so `nagare` exports them itself by evaluating
# `nagarectl context env`.
#
# Strip the CLOUDSDK_* / NAGARE_* contract from this one invocation. A DEVELOPER
# runs the rehearsal from a direnv-loaded checkout, and that profile would
# otherwise win the documented per-field precedence (environment > context) and
# make the assertion below describe the developer's machine rather than the
# context under test. NAGARE_CONTEXT is deliberately kept: selecting the context
# is the point. This is not papering over a defect — an ambient override reaching
# a real operation is exactly what `nagarectl context guard` refuses.
run_cli_clean_context() {
  env \
    -u CLOUDSDK_CORE_PROJECT -u CLOUDSDK_COMPUTE_REGION -u CLOUDSDK_COMPUTE_ZONE \
    -u NAGARE_REGISTRY_HOST -u NAGARE_ARTIFACT_REGISTRY_ID \
    -u NAGARE_IMAGE_BUCKET -u NAGARE_BACKUP_BUCKET -u NAGARE_BASE_DOMAIN \
    -u NAGARE_INSTANCE_NAME -u NAGARE_TARGET_PLATFORM -u NAGARE_SSH_USER \
    -u NAGARE_MODE -u NAGARE_LOCAL_OBJECT_STORE \
    -u NAGARE_PULUMI_BACKEND -u NAGARE_PULUMI_BACKEND_URL \
    -u NAGARE_PLATFORM_VERSION \
    -u NAGARE_ACME_EMAIL -u NAGARE_ACME_DIRECTORY \
    nix run "${flake_ref}#nagarectl" -- "$@"
}
run_cli_clean_context context env > context-env.sh
grep -q "^export NAGARE_PULUMI_STACK='rehearsal-cloud'$" context-env.sh
grep -q "^export PULUMI_BACKEND_URL='file://${test_root}/state/nagare/rehearsal-cloud/state'$" context-env.sh
grep -q "^export CLOUDSDK_CORE_PROJECT='nagare-release-rehearsal'$" context-env.sh
run_operator --dry-run infra-preview > infra-preview.out 2>&1
# The public recipe must enter the context-bound preview command. That command
# owns the project guard and runs it before Pulumi; the hermetic clone-free
# platform check proves the internal ordering with fake tools.
grep -q 'nagarectl infra preview' infra-preview.out

current_system="$(nix eval --raw --impure --expr builtins.currentSystem)"
supported_systems="$(nix eval "${flake_ref}#lib.release.supportedSystems" --json)"
jq -e --arg system "$current_system" 'index($system) != null' <<<"$supported_systems" >/dev/null \
  || die "current system $current_system is absent from the release metadata"

result="$(jq -n -S \
  --arg version "$version" \
  --arg revision "$(jq -er '.revision' version.json)" \
  --arg flakeRef "$flake_ref" \
  --arg system "$current_system" \
  --arg pulumiVersion "$(cat pulumi-version.out)" \
  --arg upgradeState "$(jq -er '.state' target-upgrade.json)" \
  --argjson previewCalls "$(grep -c 'pulumi .* preview --json --save-plan ' "$upgrade_tool_log")" \
  --argjson supportedSystems "$supported_systems" \
  '{version: $version, revision: $revision, flakeRef: $flakeRef, system: $system,
    supportedSystems: $supportedSystems, cloneFree: true,
    pulumiVersion: $pulumiVersion,
    platformUpgrade: {state: $upgradeState, previewCalls: $previewCalls},
    checks: ["version", "context", "typed-config", "payload", "host-config", "local-init", "cloud-init", "context-env", "operator-recipe", "platform-upgrade"]}')"

if [[ -n "$output" ]]; then
  mkdir -p "$(dirname "$output")"
  printf '%s\n' "$result" > "$output"
else
  printf '%s\n' "$result"
fi
