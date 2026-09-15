#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM="$(basename "$0")"

die() {
  printf '%s: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/rehearse-gcp-bootstrap.sh --hermetic | --live

  --hermetic  Rehearse the public bootstrap command sequence with recording fakes.
  --live      Run once against an explicitly authorized disposable GCP project.

Live mode is billable and ultimately destroys the rehearsal stack. It never deletes
the GCP project. See docs/user/onboarding-bring-your-own-project.md first.

Required live-mode environment:
  NAGARE_GCP_BOOTSTRAP_REHEARSAL_PROJECT
  NAGARE_GCP_BOOTSTRAP_REHEARSAL_CONTEXT
  NAGARE_GCP_BOOTSTRAP_REHEARSAL_BASE_DOMAIN
  NAGARE_GCP_BOOTSTRAP_REHEARSAL_PROTECTED_PROJECTS
  NAGARE_GCP_BOOTSTRAP_REHEARSAL_RELEASE
  NAGARE_GCP_BOOTSTRAP_REHEARSAL_ACME_EMAIL
  NAGARE_GCP_BOOTSTRAP_REHEARSAL_SSH_PUBLIC_KEY_FILE
  NAGARE_GCP_BOOTSTRAP_REHEARSAL_SOPS_FILE
  NAGARE_GCP_BOOTSTRAP_REHEARSAL_AGE_KEY_FILE
  NAGARE_GCP_BOOTSTRAP_REHEARSAL_ACK=I-understand-this-creates-billable-resources
EOF
}

state_get() {
  local key="$1"
  sed -n "s/^${key}=//p" "$NAGARE_REHEARSAL_STATE" | tail -n 1
}

state_set() {
  local key="$1" value="$2" temporary
  temporary="${NAGARE_REHEARSAL_STATE}.new"
  awk -F= -v key="$key" '$1 != key { print }' "$NAGARE_REHEARSAL_STATE" > "$temporary"
  printf '%s=%s\n' "$key" "$value" >> "$temporary"
  mv "$temporary" "$NAGARE_REHEARSAL_STATE"
}

require_state() {
  local key="$1" expected="$2" recovery="$3" actual
  actual="$(state_get "$key")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'refused: %s is %q, expected %q; recovery: %s\n' \
      "$key" "$actual" "$expected" "$recovery" >&2
    return 1
  fi
}

has_arg_pair() {
  local wanted_flag="$1" wanted_value="$2"
  shift 2
  while (( $# > 1 )); do
    if [[ "$1" == "$wanted_flag" && "$2" == "$wanted_value" ]]; then
      return 0
    fi
    shift
  done
  return 1
}

fake_trace() {
  printf '%s %s\n' "$PROGRAM" "$*" >> "${NAGARE_REHEARSAL_TRACE:?}"
}

fake_project_guard() {
  has_arg_pair --project "$NAGARE_REHEARSAL_PROJECT" "$@" || {
    printf 'refused: %s omitted exact --project %s; recovery: select the rehearsal context\n' \
      "$PROGRAM" "$NAGARE_REHEARSAL_PROJECT" >&2
    return 1
  }
}

fake_gcloud() {
  fake_trace "$@"
  case " $* " in
    *" auth list "*) printf '%s\n' operator@example.invalid ;;
    *" config get-value project "*) printf '%s\n' "$NAGARE_REHEARSAL_PROJECT" ;;
    *" compute instances describe "*)
      fake_project_guard "$@"
      require_state vm_ready yes 'wait for the original first boot to reach Ready'
      printf '{"status":"RUNNING","id":"rehearsal-vm"}\n'
      ;;
    *) fake_project_guard "$@" ;;
  esac
}

fake_pulumi() {
  fake_trace "$@"
  case " $* " in
    *" stack ls --json "*)
      if [[ "$(state_get stack_empty)" == yes ]]; then
        printf '[]\n'
      else
        printf '[{"name":"%s","current":true,"resourceCount":1}]\n' \
          "$NAGARE_REHEARSAL_CONTEXT"
      fi
      ;;
    *" preview "*)
      require_state adc_project "$NAGARE_REHEARSAL_PROJECT" \
        'run gcloud auth application-default set-quota-project for the rehearsal project'
      require_state context_project "$NAGARE_REHEARSAL_PROJECT" \
        'repair the context project before previewing'
      local phase plan_path=''
      phase="$(state_get next_plan)"
      [[ "$phase" == perimeter || "$phase" == vm ]] || \
        die "fake pulumi preview has no pending phase"
      while (( $# )); do
        if [[ "$1" == --save-plan && $# -gt 1 ]]; then
          plan_path="$2"
          break
        fi
        shift
      done
      [[ -n "$plan_path" ]] || die 'fake pulumi preview requires --save-plan'
      printf 'project=%s\ncontext=%s\nphase=%s\nrevision=%s\n' \
        "$NAGARE_REHEARSAL_PROJECT" "$NAGARE_REHEARSAL_CONTEXT" "$phase" \
        "$(state_get context_revision)" > "$plan_path"
      state_set "${phase}_reviewed" yes
      state_set "${phase}_plan" "$plan_path"
      printf '{"steps":[{"op":"create","phase":"%s"}]}\n' "$phase"
      ;;
    *" up "*)
      local phase plan_path=''
      phase="$(state_get next_plan)"
      while (( $# )); do
        if [[ "$1" == --plan && $# -gt 1 ]]; then
          plan_path="$2"
          break
        fi
        shift
      done
      [[ -n "$plan_path" && -f "$plan_path" ]] || \
        die 'refused: saved Pulumi plan is missing; recovery: preview and review a new plan'
      grep -qx "project=$NAGARE_REHEARSAL_PROJECT" "$plan_path" || \
        die 'refused: saved Pulumi plan targets another project; recovery: preview again'
      grep -qx "context=$NAGARE_REHEARSAL_CONTEXT" "$plan_path" || \
        die 'refused: saved Pulumi plan targets another context; recovery: preview again'
      grep -qx "phase=$phase" "$plan_path" || \
        die 'refused: saved Pulumi plan is for another phase; recovery: preview again'
      grep -qx "revision=$(state_get context_revision)" "$plan_path" || \
        die 'refused: saved Pulumi plan is stale; recovery: preview and review a new plan'
      require_state "${phase}_reviewed" yes 'review the saved plan before applying it'
      state_set "${phase}_applied" yes
      state_set applied_count "$(( $(state_get applied_count) + 1 ))"
      if [[ "$phase" == perimeter ]]; then
        state_set next_plan vm
      else
        state_set stack_empty no
      fi
      ;;
    *" destroy "*)
      state_set stack_empty yes
      ;;
    *) : ;;
  esac
}

fake_nix() {
  fake_trace "$@"
  require_state perimeter_applied yes 'apply the reviewed perimeter plan first'
  fake_project_guard "$@"
  state_set image_ready yes
}

fake_ssh() {
  fake_trace "$@"
  case " $* " in
    *" wait-ready "*)
      require_state vm_applied yes 'apply the reviewed VM plan first'
      state_set vm_ready yes
      ;;
    *" place-age-key "*)
      require_state vm_ready yes 'wait for the first-boot node to become Ready'
      state_set age_key_ready yes
      ;;
    *) require_state vm_ready yes 'wait for the first-boot node to become Ready' ;;
  esac
}

fake_kubectl() {
  fake_trace "$@"
  case " $* " in
    *" fetch-kubeconfig "*)
      require_state age_key_ready yes 'deliver the host age key over IAP first'
      state_set kubeconfig_node "$NAGARE_REHEARSAL_CONTEXT-nagare"
      ;;
    *" guard "*)
      require_state kubeconfig_node "$NAGARE_REHEARSAL_CONTEXT-nagare" \
        'fetch the selected context kubeconfig again'
      state_set cluster_guarded yes
      ;;
    *" bootstrap "*)
      require_state cluster_guarded yes 'run cluster guard before Kubernetes mutation'
      [[ "$(state_get node_ready)" == yes ]] || \
        die 'refused: VM node is not Ready; recovery: wait for first-boot k3s'
      [[ "$(state_get bootstrap_count)" == 0 ]] || \
        die 'refused: cluster-bootstrap already ran; recovery: retain evidence and start a new rehearsal'
      state_set bootstrap_count 1
      state_set webhooks_ready yes
      ;;
    *" enable-tls "*)
      require_state webhooks_ready yes 'wait for Knative admission webhook rollouts'
      require_state dns_delegated yes 'delegate the disposable base domain first'
      state_set tls_enabled yes
      ;;
    *" certificate-policy "*)
      require_state tls_enabled yes 'enable TLS only after DNS and webhook readiness'
      require_state certificate_scope apps-only \
        'remove internal or unlabeled public certificate names'
      ;;
    *) : ;;
  esac
}

fake_dns() {
  fake_trace "$@"
  require_state perimeter_applied yes 'apply the perimeter plan before DNS delegation'
  state_set dns_delegated yes
}

fake_main() {
  case "$PROGRAM" in
    gcloud) fake_gcloud "$@" ;;
    pulumi) fake_pulumi "$@" ;;
    nix) fake_nix "$@" ;;
    ssh) fake_ssh "$@" ;;
    kubectl) fake_kubectl "$@" ;;
    nagare-dns) fake_dns "$@" ;;
    npm) fake_trace "$@" ;;
    *) die "unknown rehearsal fake $PROGRAM" ;;
  esac
}

if [[ "${NAGARE_GCP_BOOTSTRAP_FAKE_MODE:-}" == 1 ]]; then
  fake_main "$@"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_refuses() {
  local expected="$1"
  shift
  local output="$NAGARE_REHEARSAL_ROOT/refusal.out"
  if "$@" > "$output" 2>&1; then
    printf 'expected refusal but command succeeded: %s\n' "$*" >&2
    return 1
  fi
  grep -q "$expected" "$output" || {
    printf 'refusal did not name %q:\n' "$expected" >&2
    cat "$output" >&2
    return 1
  }
}

assert_public_interfaces() {
  local init_help context_help bad_claims
  init_help="$NAGARE_REHEARSAL_ROOT/init-help.txt"
  context_help="$NAGARE_REHEARSAL_ROOT/context-create-help.txt"
  nagarectl init --help > "$init_help"
  nagarectl context create --help > "$context_help"
  awk '/^  --boot-disk-size-gb/{inside=1} inside{print} /^  --data-disk-size-gb/{exit}' \
    "$init_help" | tr '\n' ' ' | grep -q 'changing a live VM *replaces it'
  awk '/^  --boot-disk-size-gb/{inside=1} inside{print} /^  --data-disk-size-gb/{exit}' \
    "$context_help" | tr '\n' ' ' | grep -q 'changing a live VM *replaces it'

  bad_claims="$NAGARE_REHEARSAL_ROOT/boot-disk-claims.txt"
  if rg -n -i \
    '(boot.?disk.?size|bootDiskSizeGb|NAGARE_BOOT_DISK_SIZE_GB).*(growth is in.place|in.place growth|is an in.place)' \
    "$ROOT/docs/user" > "$bad_claims"; then
    printf 'user documentation still claims boot-disk size changes are in-place:\n' >&2
    cat "$bad_claims" >&2
    return 1
  fi
  rg -q -i 'data-disk.*in-place|data disk.*in-place' \
    "$ROOT/docs/user/provisioning-with-pulumi.md" \
    "$ROOT/docs/user/reference.md"

  nagarectl init "$NAGARE_REHEARSAL_CONTEXT" \
    --project "$NAGARE_REHEARSAL_PROJECT" \
    --base-domain "$NAGARE_REHEARSAL_BASE_DOMAIN" \
    --acme-email operator@example.invalid \
    --acme-directory staging --skip-preflight --dry-run \
    > "$NAGARE_REHEARSAL_ROOT/init-dry-run.txt"
  nagare --dry-run infra-preview --save-plan "$NAGARE_REHEARSAL_ROOT/public-perimeter" \
    > "$NAGARE_REHEARSAL_ROOT/infra-preview-dry-run.txt" 2>&1
  nagare --dry-run infra-up --plan "$NAGARE_REHEARSAL_ROOT/public-perimeter" --yes \
    > "$NAGARE_REHEARSAL_ROOT/infra-apply-dry-run.txt" 2>&1
  nagare --dry-run host-image > "$NAGARE_REHEARSAL_ROOT/host-image-dry-run.txt" 2>&1
  nagare --dry-run cluster-bootstrap > "$NAGARE_REHEARSAL_ROOT/bootstrap-dry-run.txt" 2>&1
  nagare --dry-run cluster-enable-tls > "$NAGARE_REHEARSAL_ROOT/tls-dry-run.txt" 2>&1

  grep -q 'nagarectl infra preview --save-plan' "$NAGARE_REHEARSAL_ROOT/infra-preview-dry-run.txt"
  grep -q 'nagarectl infra apply --plan' "$NAGARE_REHEARSAL_ROOT/infra-apply-dry-run.txt"
  grep -q 'scripts/upload-images.sh' "$NAGARE_REHEARSAL_ROOT/host-image-dry-run.txt"
  grep -q 'nagarectl cluster guard' "$NAGARE_REHEARSAL_ROOT/bootstrap-dry-run.txt"
  grep -q 'nagarectl cluster certificate-policy' "$NAGARE_REHEARSAL_ROOT/tls-dry-run.txt"
}

run_hermetic() {
  trap 'status=$?; printf "hermetic rehearsal failed at %s:%s: %s (status %s)\n" "${BASH_SOURCE[0]}" "${BASH_LINENO[0]}" "$BASH_COMMAND" "$status" >&2' ERR
  command -v nagarectl >/dev/null || die 'nagarectl is required (enter the Nagare dev shell)'
  command -v nagare >/dev/null || die 'nagare is required (enter the Nagare dev shell)'
  command -v rg >/dev/null || die 'rg is required'

  NAGARE_REHEARSAL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nagare-gcp-bootstrap.XXXXXX")"
  export NAGARE_REHEARSAL_ROOT
  trap 'rm -rf -- "$NAGARE_REHEARSAL_ROOT"' EXIT
  export HOME="$NAGARE_REHEARSAL_ROOT/home"
  export XDG_CONFIG_HOME="$NAGARE_REHEARSAL_ROOT/config"
  export XDG_STATE_HOME="$NAGARE_REHEARSAL_ROOT/state"
  export NAGARE_REHEARSAL_STATE="$NAGARE_REHEARSAL_ROOT/rehearsal.state"
  export NAGARE_REHEARSAL_TRACE="$NAGARE_REHEARSAL_ROOT/rehearsal.trace"
  export NAGARE_REHEARSAL_PROJECT=rehearsal-project
  export NAGARE_REHEARSAL_CONTEXT=rehearsal
  export NAGARE_REHEARSAL_BASE_DOMAIN=apps.rehearsal.invalid
  export NAGARE_GCP_BOOTSTRAP_FAKE_MODE=1
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$NAGARE_REHEARSAL_ROOT/bin"
  : > "$NAGARE_REHEARSAL_TRACE"
  cat > "$NAGARE_REHEARSAL_STATE" <<'EOF'
context_project=rehearsal-project
adc_project=rehearsal-project
context_revision=1
stack_empty=yes
next_plan=perimeter
perimeter_reviewed=no
perimeter_applied=no
vm_reviewed=no
vm_applied=no
applied_count=0
image_ready=no
vm_ready=no
node_ready=no
age_key_ready=no
kubeconfig_node=none
cluster_guarded=no
bootstrap_count=0
webhooks_ready=no
dns_delegated=no
tls_enabled=no
certificate_scope=apps-only
EOF
  local tool
  for tool in gcloud pulumi nix ssh kubectl nagare-dns npm; do
    ln -s "$ROOT/scripts/rehearse-gcp-bootstrap.sh" "$NAGARE_REHEARSAL_ROOT/bin/$tool"
  done
  export PATH="$NAGARE_REHEARSAL_ROOT/bin:$PATH"

  assert_public_interfaces

  # Foreign ADC quota attribution refuses before the first Pulumi mutation.
  state_set adc_project foreign-project
  assert_refuses 'adc_project' pulumi preview --save-plan "$NAGARE_REHEARSAL_ROOT/foreign.plan"
  state_set adc_project "$NAGARE_REHEARSAL_PROJECT"

  pulumi preview --save-plan "$NAGARE_REHEARSAL_ROOT/perimeter.plan" >/dev/null

  # A context change invalidates the reviewed plan before `pulumi up`.
  state_set context_revision 2
  assert_refuses 'stale' pulumi up --plan "$NAGARE_REHEARSAL_ROOT/perimeter.plan"
  state_set context_revision 1
  pulumi up --plan "$NAGARE_REHEARSAL_ROOT/perimeter.plan"

  # The builder must be context-owned unless the exact exception is acknowledged.
  assert_refuses 'omitted exact --project' nix build --project foreign-builder
  nix build --project "$NAGARE_REHEARSAL_PROJECT"

  pulumi preview --save-plan "$NAGARE_REHEARSAL_ROOT/vm.plan" >/dev/null
  pulumi up --plan "$NAGARE_REHEARSAL_ROOT/vm.plan"

  state_set cluster_guarded yes
  assert_refuses 'VM node is not Ready' kubectl bootstrap
  state_set cluster_guarded no
  assert_refuses 'vm_ready' ssh place-age-key
  ssh wait-ready
  state_set node_ready yes
  assert_refuses 'age_key_ready' kubectl fetch-kubeconfig
  ssh place-age-key
  kubectl fetch-kubeconfig

  state_set kubeconfig_node foreign-node
  assert_refuses 'kubeconfig_node' kubectl guard
  state_set kubeconfig_node "$NAGARE_REHEARSAL_CONTEXT-nagare"
  kubectl guard

  state_set webhooks_ready no
  assert_refuses 'webhooks_ready' kubectl enable-tls
  kubectl bootstrap
  nagare-dns delegate --project "$NAGARE_REHEARSAL_PROJECT"
  kubectl enable-tls
  state_set certificate_scope leaked-internal-name
  assert_refuses 'certificate_scope' kubectl certificate-policy
  state_set certificate_scope apps-only
  kubectl certificate-policy

  [[ "$(state_get applied_count)" == 2 ]] || die 'expected exactly two reviewed applies'
  [[ "$(state_get bootstrap_count)" == 1 ]] || die 'expected cluster-bootstrap exactly once'
  [[ "$(state_get vm_ready)" == yes ]] || die 'expected the first-boot node to be Ready'
  [[ "$(state_get tls_enabled)" == yes ]] || die 'expected TLS policy to pass'

  printf '%s\n' \
    'ok: two reviewed Pulumi plans applied in context project' \
    'ok: context builder and kubeconfig identities match' \
    'ok: first host boot reached Ready and cluster-bootstrap ran once' \
    'ok: public certificate policy contains only labeled app namespaces' \
    'gcp bootstrap rehearsal: PASS'
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "live mode requires $name"
}

live_command() {
  printf '%s + ' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$NAGARE_LIVE_COMMAND_LOG"
  printf '%q ' "$@" >> "$NAGARE_LIVE_COMMAND_LOG"
  printf '\n' >> "$NAGARE_LIVE_COMMAND_LOG"
  "$@"
}

confirm_exact() {
  local prompt="$1" expected="$2" answer
  [[ -t 0 && -t 1 ]] || die 'live mode requires an interactive terminal'
  printf '%s\n> ' "$prompt"
  IFS= read -r answer
  [[ "$answer" == "$expected" ]] || die 'confirmation did not match; no mutation performed'
}

run_live() {
  require_env NAGARE_GCP_BOOTSTRAP_REHEARSAL_PROJECT
  require_env NAGARE_GCP_BOOTSTRAP_REHEARSAL_CONTEXT
  require_env NAGARE_GCP_BOOTSTRAP_REHEARSAL_BASE_DOMAIN
  require_env NAGARE_GCP_BOOTSTRAP_REHEARSAL_PROTECTED_PROJECTS
  require_env NAGARE_GCP_BOOTSTRAP_REHEARSAL_RELEASE
  require_env NAGARE_GCP_BOOTSTRAP_REHEARSAL_ACME_EMAIL
  require_env NAGARE_GCP_BOOTSTRAP_REHEARSAL_SSH_PUBLIC_KEY_FILE
  require_env NAGARE_GCP_BOOTSTRAP_REHEARSAL_SOPS_FILE
  require_env NAGARE_GCP_BOOTSTRAP_REHEARSAL_AGE_KEY_FILE
  [[ "${NAGARE_GCP_BOOTSTRAP_REHEARSAL_ACK:-}" == \
      I-understand-this-creates-billable-resources ]] || \
    die 'set NAGARE_GCP_BOOTSTRAP_REHEARSAL_ACK=I-understand-this-creates-billable-resources'

  local project="$NAGARE_GCP_BOOTSTRAP_REHEARSAL_PROJECT"
  local context="$NAGARE_GCP_BOOTSTRAP_REHEARSAL_CONTEXT"
  local protected active_project adc_file adc_project installed_version expected_version
  local installed_platform installed_revision reviewed_flake reviewed_revision
  for protected in ${NAGARE_GCP_BOOTSTRAP_REHEARSAL_PROTECTED_PROJECTS//,/ }; do
    [[ "$project" != "$protected" ]] || \
      die "refusing protected/default project $project; create a disposable project"
  done
  [[ "$project" != tan-nb-exp ]] || die 'refusing historical default project tan-nb-exp'

  for command in nagare nagarectl gcloud pulumi jq kubectl nix; do
    command -v "$command" >/dev/null || die "live mode requires $command"
  done
  [[ -f "$NAGARE_GCP_BOOTSTRAP_REHEARSAL_SSH_PUBLIC_KEY_FILE" ]] || \
    die 'SSH public-key file does not exist'
  [[ -f "$NAGARE_GCP_BOOTSTRAP_REHEARSAL_SOPS_FILE" ]] || die 'sops file does not exist'
  [[ -f "$NAGARE_GCP_BOOTSTRAP_REHEARSAL_AGE_KEY_FILE" ]] || die 'age-key file does not exist'

  active_project="$(gcloud config get-value project 2>/dev/null)"
  [[ "$active_project" == "$project" ]] || \
    die "gcloud project is $active_project; run: gcloud config set project $project"
  adc_file="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
  [[ -r "$adc_file" ]] || die 'ADC file is missing; run gcloud auth application-default login'
  adc_project="$(jq -er '.quota_project_id' "$adc_file")"
  [[ "$adc_project" == "$project" ]] || \
    die "ADC quota project is $adc_project; run: gcloud auth application-default set-quota-project $project"
  export CLOUDSDK_CONFIG="$(dirname "$adc_file")"

  installed_version="$(nagarectl version --json | jq -er '.version')"
  expected_version="${NAGARE_GCP_BOOTSTRAP_REHEARSAL_RELEASE#v}"
  [[ "$installed_version" == "$expected_version" ]] || \
    die "installed Nagare $installed_version does not match reviewed release $expected_version"
  installed_platform="$(nagarectl platform root --json)"
  jq -e '.source == "installed" and (.revision | length > 0)' \
    <<< "$installed_platform" >/dev/null || \
    die 'live mode requires the installed release package, not a checkout payload'
  installed_revision="$(jq -er '.revision' <<< "$installed_platform")"
  reviewed_flake="$(nix flake metadata --json \
    "github:shinzui/nagare/$NAGARE_GCP_BOOTSTRAP_REHEARSAL_RELEASE")"
  reviewed_revision="$(jq -er '.revision' <<< "$reviewed_flake")"
  [[ "$installed_revision" == "$reviewed_revision" ]] || \
    die "installed payload revision $installed_revision does not match reviewed release revision $reviewed_revision"

  local evidence_root timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  evidence_root="${NAGARE_GCP_BOOTSTRAP_REHEARSAL_EVIDENCE_DIR:-$PWD/gcp-bootstrap-evidence-$timestamp}"
  [[ ! -e "$evidence_root" ]] || die "evidence path already exists: $evidence_root"
  mkdir -p "$evidence_root/home" "$evidence_root/config" "$evidence_root/state"
  export HOME="$evidence_root/home"
  export XDG_CONFIG_HOME="$evidence_root/config"
  export XDG_STATE_HOME="$evidence_root/state"
  export NAGARE_CONTEXT="$context"
  export NAGARE_LIVE_COMMAND_LOG="$evidence_root/commands.log"
  : > "$NAGARE_LIVE_COMMAND_LOG"
  nagarectl version --json > "$evidence_root/cli-version.json"
  printf '%s\n' "$reviewed_flake" > "$evidence_root/reviewed-release.json"

  printf '%s\n' \
    'LIVE GCP BOOTSTRAP REHEARSAL TARGET' \
    "  release: $NAGARE_GCP_BOOTSTRAP_REHEARSAL_RELEASE ($installed_version)" \
    "  project: $project" \
    "  context/stack: $context" \
    "  base domain: $NAGARE_GCP_BOOTSTRAP_REHEARSAL_BASE_DOMAIN" \
    "  VM/builder zone: ${NAGARE_GCP_BOOTSTRAP_REHEARSAL_ZONE:-us-west1-a}" \
    "  evidence: $evidence_root" \
    '  creates: APIs, buckets, DNS zone, registry, network, builder/image, VM and disks' \
    '  teardown: destroys the Pulumi stack; never deletes the project'
  confirm_exact \
    "Type $project/$context to create billable resources in the target above:" \
    "$project/$context"

  live_command nagarectl init "$context" --project "$project" \
    --base-domain "$NAGARE_GCP_BOOTSTRAP_REHEARSAL_BASE_DOMAIN" \
    --acme-email "$NAGARE_GCP_BOOTSTRAP_REHEARSAL_ACME_EMAIL" \
    --acme-directory staging
  live_command nagarectl host init --context "$context" \
    --ssh-public-key-file "$NAGARE_GCP_BOOTSTRAP_REHEARSAL_SSH_PUBLIC_KEY_FILE" \
    --sops-file "$NAGARE_GCP_BOOTSTRAP_REHEARSAL_SOPS_FILE"
  live_command nagarectl --context "$context" context guard

  local workspace_root
  nagarectl platform root --json > "$evidence_root/release.json"
  workspace_root="$(jq -er '.workspaceRoot' "$evidence_root/release.json")"
  live_command pulumi -C "$workspace_root/infra/pulumi" stack export --stack "$context" \
    > "$evidence_root/initial-stack.json"
  jq -e '[.deployment.resources[]? | select(.type != "pulumi:pulumi:Stack")] | length == 0' \
    "$evidence_root/initial-stack.json" >/dev/null || \
    die "Pulumi stack $context is not empty; evidence retained at $evidence_root"

  local perimeter_plan="$evidence_root/perimeter-plan"
  live_command nagare infra-preview --save-plan "$perimeter_plan"
  jq . "$perimeter_plan/review.json" > "$evidence_root/perimeter-review.json"
  jq . "$perimeter_plan/metadata.json" > "$evidence_root/perimeter-metadata.json"
  live_command nagare infra-up --plan "$perimeter_plan" --yes
  live_command pulumi -C "$workspace_root/infra/pulumi" stack output --json \
    > "$evidence_root/perimeter-outputs.json"

  confirm_exact \
    "Delegate $NAGARE_GCP_BOOTSTRAP_REHEARSAL_BASE_DOMAIN to the recorded Cloud DNS nameservers, then type DNS-DELEGATED:" \
    DNS-DELEGATED
  live_command nagare host-image 2>&1 | tee "$evidence_root/host-image.log"
  local image_self_link image_name image_bucket image_object
  image_self_link="$(pulumi -C "$workspace_root/infra/pulumi" config get nagare:nagareImageSelfLink \
    --stack "$context")"
  image_name="${image_self_link##*/}"
  image_bucket="$(pulumi -C "$workspace_root/infra/pulumi" config get nagare:imageBucket \
    --stack "$context")"
  image_object="gs://$image_bucket/$image_name.raw.tar.gz"
  printf '%s\n' "$image_self_link" > "$evidence_root/registered-image.txt"
  printf '%s\n' "$image_object" > "$evidence_root/image-object.txt"

  local vm_plan="$evidence_root/first-vm-plan"
  live_command nagare infra-preview --save-plan "$vm_plan"
  jq . "$vm_plan/review.json" > "$evidence_root/first-vm-review.json"
  jq . "$vm_plan/metadata.json" > "$evidence_root/first-vm-metadata.json"
  live_command nagare infra-up --plan "$vm_plan" --yes

  local instance="${NAGARE_GCP_BOOTSTRAP_REHEARSAL_INSTANCE:-nagare-01}"
  local zone="${NAGARE_GCP_BOOTSTRAP_REHEARSAL_ZONE:-us-west1-a}"
  local ready_attempt
  for ready_attempt in $(seq 1 60); do
    if gcloud compute ssh "$instance" --project "$project" --zone "$zone" --tunnel-through-iap \
      --command='sudo k3s kubectl get node -o json' > "$evidence_root/first-ready-node.json" 2>/dev/null && \
      jq -e '(.items | length) == 1 and any(.items[0].status.conditions[]; .type == "Ready" and .status == "True")' \
        "$evidence_root/first-ready-node.json" >/dev/null; then
      break
    fi
    [[ "$ready_attempt" != 60 ]] || \
      die "VM did not reach one Ready node; evidence retained at $evidence_root"
    sleep 10
  done
  gcloud compute ssh "$instance" --project "$project" --zone "$zone" --tunnel-through-iap \
    --command='cat /proc/sys/kernel/random/boot_id' > "$evidence_root/first-boot-id.txt"

  live_command nagarectl host place-age-key --context "$context" \
    --key-file "$NAGARE_GCP_BOOTSTRAP_REHEARSAL_AGE_KEY_FILE"
  live_command nagarectl --context "$context" server status \
    | tee "$evidence_root/post-age-key-status.txt"
  grep -q 'OK.*host age key' "$evidence_root/post-age-key-status.txt" || \
    die "host age key did not report ready; evidence retained at $evidence_root"
  live_command nagarectl kubeconfig fetch --context "$context"
  export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$context.yaml"
  live_command nagarectl cluster guard --context "$context"

  printf '%s\n' 'cluster-bootstrap invocation 1' >> "$NAGARE_LIVE_COMMAND_LOG"
  local bootstrap_status
  set +e
  live_command nagare cluster-bootstrap 2>&1 | tee "$evidence_root/cluster-bootstrap.log"
  bootstrap_status="$?"
  set -e
  printf '%s\n' "$bootstrap_status" > "$evidence_root/cluster-bootstrap-exit-status.txt"
  [[ "$bootstrap_status" == 0 ]] || \
    die "cluster-bootstrap failed on its first invocation; evidence retained at $evidence_root"
  live_command nagare cluster-enable-tls 2>&1 | tee "$evidence_root/cluster-enable-tls.log"
  local certificate_attempt
  for certificate_attempt in $(seq 1 60); do
    if kubectl -n personal get certificate -o json \
      | jq -e '.items | length > 0' >/dev/null; then
      break
    fi
    [[ "$certificate_attempt" != 60 ]] || \
      die "no personal namespace certificate appeared; evidence retained at $evidence_root"
    sleep 10
  done
  live_command kubectl -n personal wait --for=condition=Ready certificate --all --timeout=10m \
    2>&1 | tee "$evidence_root/certificate-readiness.log"
  live_command nagarectl --context "$context" cluster certificate-policy \
    2>&1 | tee "$evidence_root/certificate-policy.log"
  live_command kubectl get nodes -o json > "$evidence_root/final-nodes.json"
  live_command kubectl get certificates -A -o json > "$evidence_root/certificates.json"
  jq -e '[.items[] | select(.metadata.namespace == "personal") |
      select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length > 0' \
    "$evidence_root/certificates.json" >/dev/null || \
    die "personal certificate is not Ready; evidence retained at $evidence_root"
  live_command kubectl get deployments -n knative-serving -o json \
    > "$evidence_root/knative-deployments.json"
  live_command nagare status 2>&1 | tee "$evidence_root/status.log"
  live_command nagarectl --context "$context" doctor 2>&1 | tee "$evidence_root/doctor.log"

  [[ "$(grep -c '^cluster-bootstrap invocation ' "$NAGARE_LIVE_COMMAND_LOG")" == 1 ]] || \
    die 'cluster-bootstrap invocation count was not exactly one'
  confirm_exact \
    "Acceptance passed. Type DESTROY-$project/$context to destroy the stack (the project is retained):" \
    "DESTROY-$project/$context"
  live_command gcloud compute images delete "$image_name" --project "$project" --quiet
  live_command gcloud storage rm "$image_object"
  live_command pulumi -C "$workspace_root/infra/pulumi" config set \
    nagare:vmDeletionProtection false --stack "$context"
  local teardown_plan="$evidence_root/teardown-protection-off-plan"
  live_command nagare infra-preview --save-plan "$teardown_plan"
  jq . "$teardown_plan/review.json" > "$evidence_root/teardown-protection-off-review.json"
  jq . "$teardown_plan/metadata.json" > "$evidence_root/teardown-protection-off-metadata.json"
  live_command nagare infra-up --plan "$teardown_plan" --yes
  live_command pulumi -C "$workspace_root/infra/pulumi" state unprotect --all --yes \
    --stack "$context"
  live_command nagare infra-destroy --yes
  live_command pulumi -C "$workspace_root/infra/pulumi" stack export --stack "$context" \
    > "$evidence_root/final-stack.json"
  if ! jq -e '[.deployment.resources[]? | select(.type != "pulumi:pulumi:Stack")] | length == 0' \
    "$evidence_root/final-stack.json" >/dev/null; then
    jq -r '.deployment.resources[]? | select(.type != "pulumi:pulumi:Stack") | .urn' \
      "$evidence_root/final-stack.json" >&2
    die "teardown left the resources above; evidence retained at $evidence_root"
  fi
  printf '%s\n' "live rehearsal complete; evidence retained at $evidence_root"
}

[[ $# == 1 ]] || {
  usage >&2
  exit 2
}
case "$1" in
  --hermetic) run_hermetic ;;
  --live) run_live ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
