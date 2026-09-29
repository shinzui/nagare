#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$repo_root/fixtures/inventory-release/gcp/ep150-target.json"
generic="$repo_root/scripts/rehearse-managed-resources.sh"

usage() {
  cat <<'EOF'
Usage: scripts/rehearse-gcp-inventory-release.sh --phase plan|apply|verify \
  --context NAME --expected-project PROJECT --expected-cluster CLUSTER \
  --evidence-dir DIRECTORY [--candidate COMPILED_DIRECTORY] [--yes]

Without --candidate, plan/apply use one saved public platform-bootstrap review.
Repeat with a new evidence directory for each bootstrap stage. With --candidate,
plan/verify use the generic Kubernetes-backed inventory rehearsal. Apply reads
the saved stage and requires --yes. Set XDG_CONFIG_HOME and XDG_STATE_HOME to
an isolated disposable operator root before using this runner.
EOF
}

die() { printf 'GCP inventory rehearsal: %s\n' "$*" >&2; exit 1; }

digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

phase=""
context=""
project=""
cluster=""
evidence=""
candidate=""
yes=false
while (($#)); do
  case "$1" in
    --phase|--context|--expected-project|--expected-cluster|--evidence-dir|--candidate)
      (($# >= 2)) || die "$1 requires a value"
      case "$1" in
        --phase) phase="$2" ;;
        --context) context="$2" ;;
        --expected-project) project="$2" ;;
        --expected-cluster) cluster="$2" ;;
        --evidence-dir) evidence="$2" ;;
        --candidate) candidate="$2" ;;
      esac
      shift 2 ;;
    --yes) yes=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$phase" == plan || "$phase" == apply || "$phase" == verify ]] || die "invalid phase"
[[ -n "$context" && -n "$project" && -n "$cluster" && -n "$evidence" ]] || die "target arguments are required"
jq -e --arg context "$context" --arg project "$project" --arg cluster "$cluster" \
  '.schemaVersion == 1 and .context == $context and .project == $project and .cluster == $cluster' \
  "$fixture" >/dev/null || die "target differs from the checked-in disposable fixture"
[[ -n "${XDG_CONFIG_HOME:-}" && -n "${XDG_STATE_HOME:-}" ]] || die "isolated XDG_CONFIG_HOME and XDG_STATE_HOME are required"
[[ "$XDG_CONFIG_HOME" == /* && "$XDG_STATE_HOME" == /* ]] || die "operator roots must be absolute"
[[ "$XDG_CONFIG_HOME" != "$HOME/.config" && "$XDG_STATE_HOME" != "$HOME/.local/state" ]] || die "standing operator roots are refused"
cli="$(command -v "${NAGARECTL_BIN:-nagarectl}")" || die "nagarectl is required"
credential_env=()
if [[ -n "${NAGARE_HOST_AGE_KEY_FILE:-}" ]]; then
  [[ "${NAGARE_HOST_AGE_KEY_FILE}" == /* && -f "${NAGARE_HOST_AGE_KEY_FILE}" ]] \
    || die "NAGARE_HOST_AGE_KEY_FILE must name an absolute regular file"
  credential_env=("NAGARE_HOST_AGE_KEY_FILE=${NAGARE_HOST_AGE_KEY_FILE}")
fi
if [[ -n "${SSH_KEY:-}" ]]; then
  [[ "${SSH_KEY}" == /* && -f "${SSH_KEY}" && -f "${SSH_KEY}.pub" ]] \
    || die "SSH_KEY must name an absolute private key with its public key"
  credential_env+=("SSH_KEY=${SSH_KEY}")
fi
gcloud_configuration="$(jq -er .gcloudConfiguration "$fixture")"
configured_project="$(env CLOUDSDK_ACTIVE_CONFIG_NAME="$gcloud_configuration" \
  gcloud config get-value project 2>/dev/null)"
[[ "$configured_project" == "$project" ]] || die "named gcloud configuration targets another project"

run_cli() {
  env -i HOME="$HOME" USER="${USER:-operator}" PATH="$PATH" \
    CLOUDSDK_CORE_PROJECT="$project" CLOUDSDK_ACTIVE_CONFIG_NAME="$gcloud_configuration" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_STATE_HOME="$XDG_STATE_HOME" "${credential_env[@]}" \
    "$cli" --context "$context" "$@"
}

check_uninitialized_stack_config() {
  local review_json="$1" config_file
  config_file="$XDG_CONFIG_HOME/nagare/pulumi/Pulumi.$context.yaml"
  if jq -e '[.operations[] | select(.operation.action.tag == "CreateResource")
      | .operation.resources[] | contains("/pulumi-stack/")] | any' \
      "$review_json" >/dev/null; then
    [[ ! -s "$config_file" ]] || die "new stack has preexisting Pulumi config; isolate local previews before apply"
  fi
}

profile="$(run_cli context show)" || die "selected context is unavailable"
while IFS=$'\t' read -r variable field; do
  expected="$(jq -er ".$field" "$fixture")"
  grep -Fx "export $variable=$expected" <<<"$profile" >/dev/null \
    || die "selected context $variable differs from fixture"
done <<'FIELDS'
CLOUDSDK_CORE_PROJECT	project
CLOUDSDK_COMPUTE_REGION	region
CLOUDSDK_COMPUTE_ZONE	zone
NAGARE_BASE_DOMAIN	domain
NAGARE_INSTANCE_NAME	instance
NAGARE_SERVICE_ACCOUNT_ID	serviceAccountId
NAGARE_ARTIFACT_REGISTRY_ID	artifactRegistryId
NAGARE_IMAGE_BUCKET	imageBucket
NAGARE_BACKUP_BUCKET	backupBucket
NAGARE_NIX_CACHE_BUCKET	nixCacheBucket
FIELDS
state_bucket="$(jq -er .stateBucket "$fixture")"
grep -Fx "export NAGARE_PULUMI_BACKEND_URL=gs://$state_bucket/pulumi" <<<"$profile" >/dev/null \
  || die "Pulumi state backend differs from fixture"
grep -Fx "export NAGARE_INVENTORY_STORE_URL=gs://$state_bucket/inventory" <<<"$profile" >/dev/null \
  || die "inventory history backend differs from fixture"

project_id="$(env CLOUDSDK_ACTIVE_CONFIG_NAME="$gcloud_configuration" \
  gcloud projects describe "$project" --format='value(projectId)')"
[[ "$project_id" == "$project" ]] || die "GCP project preflight failed"

common=(--mode cloud --context "$context" --expected-project "$project"
  --expected-cluster "$cluster" --kube-context "$context"
  --kube-cluster "$context" --evidence-dir "$evidence")
if [[ -n "$candidate" || "$phase" == verify || ( "$phase" == apply && ! -f "$evidence/gcp-stage.json" ) ]]; then
  kubeconfig="$XDG_CONFIG_HOME/nagare/kubeconfigs/$context.yaml"
  [[ -f "$kubeconfig" && ! -L "$kubeconfig" ]] || die "selected context has no isolated Nagare kubeconfig"
fi
if [[ "$phase" == verify ]]; then
  [[ -n "$candidate" && "$yes" == false ]] || die "verify requires a candidate and no --yes"
  env -i HOME="$HOME" USER="${USER:-operator}" PATH="$PATH" \
    CLOUDSDK_CORE_PROJECT="$project" CLOUDSDK_ACTIVE_CONFIG_NAME="$gcloud_configuration" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_STATE_HOME="$XDG_STATE_HOME" KUBECONFIG="$kubeconfig" NAGARECTL_BIN="$cli" \
    "$generic" --phase verify "${common[@]}" --candidate "$candidate"
  exit
fi

if [[ "$phase" == plan ]]; then
  [[ "$yes" == false ]] || die "plan refuses --yes"
  if [[ -n "$candidate" ]]; then
    env -i HOME="$HOME" USER="${USER:-operator}" PATH="$PATH" \
      CLOUDSDK_CORE_PROJECT="$project" CLOUDSDK_ACTIVE_CONFIG_NAME="$gcloud_configuration" \
      XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
      XDG_STATE_HOME="$XDG_STATE_HOME" KUBECONFIG="$kubeconfig" NAGARECTL_BIN="$cli" \
      "$generic" --phase plan "${common[@]}" --candidate "$candidate"
    exit
  fi
  [[ ! -e "$evidence" ]] || die "evidence directory already exists"
  mkdir -m 700 -p "$evidence"
  cp "$fixture" "$evidence/target.json"
  run_cli version --json | jq -S . > "$evidence/operator-version.json"
  run_cli platform bootstrap plan --out "$evidence/review" > "$evidence/plan.out"
  jq -e '.operations | length > 0' "$evidence/review/review.json" >/dev/null \
    || die "bootstrap review has no operations"
  check_uninitialized_stack_config "$evidence/review/review.json"
  jq -e '[.operations[].summary] | all((contains("nagare-node") or contains("tan-ng-labs-nagare-backups") or contains("tan-ng-labs-nagare-images")) | not)' \
    "$evidence/review/review.json" >/dev/null || die "review names a standing fixture resource"
  jq -n -S --arg digest "$(digest "$evidence/review/review.json")" \
    '{stage:"bootstrap",state:"planned",reviewDigest:$digest}' > "$evidence/gcp-stage.json"
  printf 'Saved bootstrap review %s\n' "$evidence/review/review.json"
  exit
fi

[[ -z "$candidate" && "$yes" == true ]] || die "apply requires --yes and the saved review"
if [[ ! -f "$evidence/gcp-stage.json" ]]; then
  env -i HOME="$HOME" USER="${USER:-operator}" PATH="$PATH" \
    CLOUDSDK_CORE_PROJECT="$project" CLOUDSDK_ACTIVE_CONFIG_NAME="$gcloud_configuration" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_STATE_HOME="$XDG_STATE_HOME" KUBECONFIG="$kubeconfig" NAGARECTL_BIN="$cli" \
    "$generic" --phase apply "${common[@]}" --yes
  exit
fi
cmp -s "$fixture" "$evidence/target.json" || die "saved target changed"
cmp -s "$evidence/operator-version.json" <(run_cli version --json | jq -S .) \
  || die "operator changed since review"
jq -e --arg digest "$(digest "$evidence/review/review.json")" \
  '.stage == "bootstrap" and .state == "planned" and .reviewDigest == $digest' \
  "$evidence/gcp-stage.json" >/dev/null || die "saved review is not the planned review"
check_uninitialized_stack_config "$evidence/review/review.json"
jq -S '.state="applying"' "$evidence/gcp-stage.json" > "$evidence/gcp-stage.tmp"
mv "$evidence/gcp-stage.tmp" "$evidence/gcp-stage.json"
run_cli platform bootstrap apply "$evidence/review" --yes
jq -S '.state="applied"' "$evidence/gcp-stage.json" > "$evidence/gcp-stage.tmp"
mv "$evidence/gcp-stage.tmp" "$evidence/gcp-stage.json"
printf 'Applied saved bootstrap review %s\n' "$evidence/review/review.json"
