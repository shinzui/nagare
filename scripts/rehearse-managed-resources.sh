#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/rehearse-managed-resources.sh --phase plan|apply|verify \
  --mode local|cloud --context NAME --expected-cluster CLUSTER \
  [--expected-project PROJECT] [--candidate COMPILED_DIRECTORY] \
  --evidence-dir DIRECTORY [--yes]

Plan and verify require a candidate compiled by nagarectl inventory compile.
Apply consumes the saved review and requires --yes. Verify requires a fresh
candidate compiled from the accepted post-apply snapshot and proves that its
review has no operations. Cloud mode requires an exact expected GCP project;
local mode refuses one and makes no cloud preflight call.
EOF
}

die() { printf 'managed-resource rehearsal: %s\n' "$*" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

phase=""
mode=""
context=""
expected_cluster=""
expected_project=""
candidate=""
evidence_dir=""
yes=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase|--mode|--context|--expected-cluster|--expected-project|--candidate|--evidence-dir)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      case "$1" in
        --phase) phase="$2" ;;
        --mode) mode="$2" ;;
        --context) context="$2" ;;
        --expected-cluster) expected_cluster="$2" ;;
        --expected-project) expected_project="$2" ;;
        --candidate) candidate="$2" ;;
        --evidence-dir) evidence_dir="$2" ;;
      esac
      shift 2 ;;
    --yes) yes=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$phase" == plan || "$phase" == apply || "$phase" == verify ]] || die "--phase must be plan, apply, or verify"
[[ "$mode" == local || "$mode" == cloud ]] || die "--mode must be local or cloud"
[[ -n "$context" && -n "$expected_cluster" && -n "$evidence_dir" ]] || die "context, expected cluster, and evidence directory are required"
if [[ "$mode" == cloud ]]; then
  [[ -n "$expected_project" ]] || die "cloud mode requires --expected-project"
else
  [[ -z "$expected_project" ]] || die "local mode refuses --expected-project"
fi
if [[ "$phase" == apply ]]; then
  [[ -z "$candidate" && "$yes" == true ]] || die "apply requires --yes and no --candidate"
else
  [[ -d "$candidate" && "$yes" == false ]] || die "$phase requires --candidate and refuses --yes"
  [[ -f "$candidate/candidate.json" && -f "$candidate/candidate.sha256" ]] || die "candidate is not a compiled inventory directory"
fi

cli="${NAGARECTL_BIN:-nagarectl}"
command -v "$cli" >/dev/null 2>&1 || die "nagarectl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required"

# The context guard is the operator's authoritative project preflight. Local
# mode returns before any gcloud or Pulumi call. Kubernetes configuration is
# read without --raw so credentials do not enter rehearsal evidence.
guard_json="$($cli --context "$context" context guard --json)"
if [[ "$mode" == local ]]; then
  jq -e --arg context "$context" '.confined == true and .mode == "local" and .context == $context' \
    <<<"$guard_json" >/dev/null || die "selected context is not the expected local context"
else
  jq -e --arg context "$context" --arg project "$expected_project" \
    '.confined == true and .observations.context == $context and .observations.declaredProject == $project' \
    <<<"$guard_json" >/dev/null || die "selected context or GCP project differs from the reviewed target"
fi
cluster="$(kubectl config view -o json | jq -er --arg context "$context" \
  '[.contexts[] | select(.name == $context) | .context.cluster] | if length == 1 then .[0] else error("context has no unique cluster") end')"
[[ "$cluster" == "$expected_cluster" ]] || die "Kubernetes context $context selects cluster $cluster, expected $expected_cluster"

if [[ "$phase" == plan ]]; then
  [[ ! -e "$evidence_dir" ]] || die "evidence directory already exists; refusing to replace a review or completed evidence"
  mkdir -m 700 -p "$evidence_dir"
  jq -n -S --arg context "$context" --arg mode "$mode" \
    --arg project "$expected_project" --arg cluster "$cluster" \
    '{schemaVersion: 1, context: $context, mode: $mode,
      expectedProject: (if $mode == "cloud" then $project else null end),
      expectedCluster: $cluster}' > "$evidence_dir/target.json"
  printf '%s\n' "$guard_json" | jq -S . > "$evidence_dir/context-guard.json"
  candidate_digest="$(cat "$candidate/candidate.sha256")"
  [[ "$candidate_digest" == "$(sha256_file "$candidate/candidate.json")" ]] || die "candidate manifest digest differs from candidate.sha256"
  cp "$candidate/candidate.json" "$evidence_dir/candidate.json"
  printf '%s\n' "$candidate_digest" > "$evidence_dir/candidate.sha256"
  printf 'Target: context=%s mode=%s project=%s cluster=%s\n' "$context" "$mode" "${expected_project:-none}" "$cluster"
  printf 'Declared inventory: %s (sha256 %s)\n' "$evidence_dir/candidate.json" "$candidate_digest"
  "$cli" --context "$context" inventory plan --inventory "$candidate" --out "$evidence_dir/review"
  review_digest="$(cat "$evidence_dir/review/review.sha256")"
  [[ "$review_digest" == "$(sha256_file "$evidence_dir/review/review.json")" ]] || die "review digest does not match reviewed bytes"
  jq -n -S --arg candidate "$candidate_digest" --arg review "$review_digest" \
    '{candidateDigest: $candidate, reviewDigest: $review, state: "planned"}' > "$evidence_dir/run.json"
  printf 'Review: %s (sha256 %s)\n' "$evidence_dir/review/review.json" "$review_digest"
  exit 0
fi

[[ -f "$evidence_dir/target.json" && -f "$evidence_dir/run.json" ]] || die "evidence directory has no saved target and review"
jq -e --arg context "$context" --arg mode "$mode" --arg project "$expected_project" --arg cluster "$cluster" \
  '.schemaVersion == 1 and .context == $context and .mode == $mode
    and .expectedProject == (if $mode == "cloud" then $project else null end)
    and .expectedCluster == $cluster' "$evidence_dir/target.json" >/dev/null \
  || die "saved target differs from requested context, project, or cluster"
[[ "$(jq -er '.reviewDigest' "$evidence_dir/run.json")" == "$(sha256_file "$evidence_dir/review/review.json")" ]] \
  || die "saved review bytes changed"

if [[ "$phase" == apply ]]; then
  jq -e '.state == "planned"' "$evidence_dir/run.json" >/dev/null || die "review is not in planned state"
  printf 'Applying reviewed context=%s project=%s cluster=%s review=%s\n' \
    "$context" "${expected_project:-none}" "$cluster" "$(jq -r '.reviewDigest' "$evidence_dir/run.json")"
  jq -S '.state = "applying"' "$evidence_dir/run.json" > "$evidence_dir/run.tmp"
  mv "$evidence_dir/run.tmp" "$evidence_dir/run.json"
  "$cli" --context "$context" inventory apply "$evidence_dir/review" --yes
  "$cli" --context "$context" inventory status --json > "$evidence_dir/after-apply.json"
  jq -S '.state = "applied"' "$evidence_dir/run.json" > "$evidence_dir/run.tmp"
  mv "$evidence_dir/run.tmp" "$evidence_dir/run.json"
  printf 'Applied; observations: %s\n' "$evidence_dir/after-apply.json"
  exit 0
fi

jq -e '.state == "applied"' "$evidence_dir/run.json" >/dev/null || die "verify requires a completed apply"
candidate_digest="$(cat "$candidate/candidate.sha256")"
[[ "$candidate_digest" == "$(sha256_file "$candidate/candidate.json")" ]] || die "verification candidate digest differs from candidate.sha256"
"$cli" --context "$context" inventory plan --inventory "$candidate" --out "$evidence_dir/no-op-review"
jq -e '.operations == []' "$evidence_dir/no-op-review/review.json" >/dev/null \
  || die "unchanged candidate has planned operations; no-op convergence is unproved"
"$cli" --context "$context" inventory status --json > "$evidence_dir/final-observation.json"
jq -S --arg candidate "$candidate_digest" \
  '.state = "verified" | .verificationCandidateDigest = $candidate | .noOp = true' \
  "$evidence_dir/run.json" > "$evidence_dir/run.tmp"
mv "$evidence_dir/run.tmp" "$evidence_dir/run.json"
printf 'Verified no-op review and final observations: %s\n' "$evidence_dir"
