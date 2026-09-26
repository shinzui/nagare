#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/assemble-managed-resource-evidence.sh \
  --release-manifest FILE --system SYSTEM --rehearsal-dir DIR \
  --private-store-export DIR --coverage-result FILE --output FILE

Project a verified disposable rehearsal and private inventory export into one
public, structurally redacted release-evidence manifest. The private export is
read and digest-checked but never copied to the output.
EOF
}

die() { printf 'managed-resource evidence: %s\n' "$*" >&2; exit 1; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}
sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d ' ' -f 1
  else
    shasum -a 256 | cut -d ' ' -f 1
  fi
}

release_manifest=""
system=""
rehearsal_dir=""
private_store_export=""
coverage_result=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-manifest|--system|--rehearsal-dir|--private-store-export|--coverage-result|--output)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      case "$1" in
        --release-manifest) release_manifest="$2" ;;
        --system) system="$2" ;;
        --rehearsal-dir) rehearsal_dir="$2" ;;
        --private-store-export) private_store_export="$2" ;;
        --coverage-result) coverage_result="$2" ;;
        --output) output="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
[[ -n "$release_manifest" && -n "$system" && -n "$rehearsal_dir" && -n "$private_store_export" && -n "$coverage_result" && -n "$output" ]] \
  || die "all six inputs are required"
for file in "$release_manifest" "$coverage_result" \
  "$rehearsal_dir/target.json" "$rehearsal_dir/run.json" \
  "$rehearsal_dir/operator-version.json" \
  "$rehearsal_dir/candidate.json" "$rehearsal_dir/candidate.sha256" \
  "$rehearsal_dir/review/review.json" "$rehearsal_dir/review/review.sha256" \
  "$rehearsal_dir/no-op-review/review.json" "$rehearsal_dir/final-observation.json" \
  "$private_store_export/backup.json" "$private_store_export/head.json"; do
  [[ -f "$file" && ! -L "$file" ]] || die "missing or linked evidence member: $file"
done

candidate_digest="$(sha256_file "$rehearsal_dir/candidate.json")"
review_digest="$(sha256_file "$rehearsal_dir/review/review.json")"
[[ "$(cat "$rehearsal_dir/candidate.sha256")" == "$candidate_digest" ]] || die "candidate bytes changed"
[[ "$(cat "$rehearsal_dir/review/review.sha256")" == "$review_digest" ]] || die "review bytes changed"
jq -e --arg candidate "$candidate_digest" --arg review "$review_digest" \
  '.state == "verified" and .noOp == true and .candidateDigest == $candidate
    and .reviewDigest == $review and (.verificationCandidateDigest | type == "string" and length == 64)' \
  "$rehearsal_dir/run.json" >/dev/null || die "rehearsal has no verified, unchanged review"
jq -e --arg candidate "$candidate_digest" \
  '.version == 1 and .candidateDigest == $candidate and (.operations | length > 0)' \
  "$rehearsal_dir/review/review.json" >/dev/null || die "initial review has no bound operations"
jq -e --slurpfile run "$rehearsal_dir/run.json" \
  '.version == 1 and .operations == [] and .candidateDigest == $run[0].verificationCandidateDigest' \
  "$rehearsal_dir/no-op-review/review.json" >/dev/null || die "fresh review does not prove a no-op"
jq -e --slurpfile reviewed "$rehearsal_dir/review/review.json" \
  '.observationComplete == true and .activeTransaction == null
    and .missingProviders == [] and .accepted == .converged
    and .accepted == $reviewed[0].desiredRevisions' \
  "$rehearsal_dir/final-observation.json" >/dev/null || die "final observation is incomplete or diverged"
jq -e '.schemaVersion == 1 and .complete == true' "$coverage_result" >/dev/null \
  || die "mutation coverage is incomplete"
jq -e '.schemaVersion == 1 and (.context | type == "string" and length > 0)
  and (.mode == "local" or .mode == "cloud") and (.expectedCluster | type == "string" and length > 0)
  and (if .mode == "cloud" then (.expectedProject | type == "string" and length > 0)
       else .expectedProject == null end)' "$rehearsal_dir/target.json" >/dev/null \
  || die "rehearsal target is not explicit"

payload_digest="$(jq -er --arg system "$system" '
  if .payloadDigests then .payloadDigests[$system]
  elif (.systems | index($system)) then .payloadDigest
  else empty end | select(type == "string" and length > 0)' "$release_manifest")" \
  || die "release manifest has no payload identity for $system"
jq -e '.consistent == true and (.version | type == "string" and length > 0)
  and (.revision | type == "string" and length > 0)' "$release_manifest" >/dev/null \
  || die "release manifest is not a consistent candidate"
jq -e --slurpfile release "$release_manifest" \
  '.version == $release[0].version and .revision == $release[0].revision' \
  "$rehearsal_dir/operator-version.json" >/dev/null \
  || die "rehearsal operator does not match the release candidate"

receipts='[]'
transaction="tx-$review_digest"
converged=false
head_digest=''
jq -e '.version == 1 and (.members | type == "array" and length > 0)
  and ((.members | map(.path) | unique | length) == (.members | length))' \
  "$private_store_export/backup.json" >/dev/null || die "private store export is invalid"
head_sequence="$(jq -er '.sequence | select(type == "number" and . >= 0)' "$private_store_export/head.json")" \
  || die "private head has no committed journal sequence"
while IFS=$'\t' read -r member digest; do
  [[ "$member" =~ ^[A-Za-z0-9_./-]+$ && "$member" != /* && "$member" != *../* && "$member" != *'//'* ]] \
    || die "unsafe private export member path"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "invalid private export digest"
  [[ -f "$private_store_export/$member" && ! -L "$private_store_export/$member" ]] \
    || die "private export member is missing or linked: $member"
  [[ "$(sha256_file "$private_store_export/$member")" == "$digest" ]] \
    || die "private export member changed: $member"
  if [[ "$member" == head.json ]]; then
    head_digest="$digest"
  elif [[ "$member" == journal/*.json ]]; then
    jq -e \
      '.version == 1 and (.sequence | type == "number" and . >= 0)
        and (.transaction | type == "string" and length > 0)
        and (.operation == null or (.operation | type == "string"))
        and (.state.tag | type == "string")' \
      "$private_store_export/$member" >/dev/null || die "invalid journal member: $member"
    if jq -e --arg transaction "$transaction" --argjson committed "$head_sequence" \
      '.sequence < $committed and .transaction == $transaction
        and .operation == null and (.detail | contains("converged"))' \
      "$private_store_export/$member" >/dev/null; then
      converged=true
    fi
    entry="$(jq -c --arg path "$member" --arg digest "$digest" \
      --argjson committed "$head_sequence" --arg transaction "$transaction" \
      'if .sequence < $committed and .transaction == $transaction
          and .operation != null and .state.tag == "Completed"
       then {journal: $path, journalDigest: $digest, operation: .operation,
             receiptDigest: .state.contents} else empty end' \
      "$private_store_export/$member")"
    if [[ -n "$entry" ]]; then
      receipts="$(jq -cn --argjson previous "$receipts" --argjson entry "$entry" '$previous + [$entry]')"
    fi
  fi
done < <(jq -r '.members[] | [.path, .digest] | @tsv' "$private_store_export/backup.json")
[[ -n "$head_digest" ]] || die "private export has no head"
[[ "$(jq -r 'length' <<<"$receipts")" -gt 0 ]] || die "private export has no completed component receipt"
jq -e --argjson receipts "$receipts" '
  ([.operations[].operation.id] | sort) == ([$receipts[].operation] | sort)
    and ($receipts | all(.receiptDigest | type == "string" and test("^[0-9a-f]{64}$")))' \
  "$rehearsal_dir/review/review.json" >/dev/null \
  || die "completed component receipts do not match the reviewed operations"
[[ "$converged" == true ]] || die "private export has no committed convergence event for the reviewed transaction"
jq -e --slurpfile reviewed "$rehearsal_dir/review/review.json" \
  --slurpfile final "$rehearsal_dir/final-observation.json" \
  '.version == 1 and .activeTransaction == null and .executorClaim == null
    and .binding == $reviewed[0].context and .binding == $final[0].context
    and .accepted == $final[0].accepted and .converged == $final[0].converged' \
  "$private_store_export/head.json" >/dev/null || die "private head differs from the verified context"

fixture_digest="$(jq -cS . "$rehearsal_dir/target.json" | sha256_text)"
run_id="$(jq -cnS --arg payload "$payload_digest" --arg fixture "$fixture_digest" \
  --arg review "$review_digest" --arg head "$head_digest" \
  '{payload: $payload, fixture: $fixture, review: $review, head: $head}' | sha256_text)"
manifest="$(jq -nS \
  --slurpfile release "$release_manifest" \
  --slurpfile target "$rehearsal_dir/target.json" \
  --slurpfile reviewed "$rehearsal_dir/review/review.json" \
  --slurpfile operator "$rehearsal_dir/operator-version.json" \
  --slurpfile final "$rehearsal_dir/final-observation.json" \
  --arg system "$system" --arg payload "$payload_digest" \
  --arg fixture "$fixture_digest" --arg run "$run_id" \
  --arg candidate "$candidate_digest" --arg review "$review_digest" \
  --arg head "$head_digest" --arg coverage "$(sha256_file "$coverage_result")" \
  --argjson receipts "$receipts" \
  '{schemaVersion: 1,
    payload: {version: $release[0].version, sourceRevision: $release[0].revision,
      system: $system, digest: $payload},
    run: {id: $run, fixtureDigest: $fixture, mode: $target[0].mode},
    inventoryDigest: $candidate,
    scopeRevisions: [$final[0].accepted[] | {scope: {kind: .scope.kind, name: .scope.name},
      revision: {generation: .revision.generation, digest: .revision.digest}}],
    reviewedChangeDigest: $review, privateStoreHeadDigest: $head,
    componentReceipts: $receipts,
    finalObservation: {complete: $final[0].observationComplete,
      findings: ($final[0].findings | group_by(.category) | map({category: .[0].category, count: length})),
      retainedCount: ($final[0].retained | length)},
    tools: {operator: {version: $operator[0].version, revision: $operator[0].revision},
      adapters: [$final[0].providers[] | {executor, identity, version}]},
    coverage: {complete: true, resultDigest: $coverage}}')" \
  || die "could not project public evidence"

mkdir -p "$(dirname "$output")"
staging="$(mktemp "$(dirname "$output")/.managed-evidence.XXXXXX")"
trap 'rm -f -- "$staging"' EXIT
printf '%s\n' "$manifest" > "$staging"
if [[ -e "$output" ]]; then
  [[ -f "$output" && ! -L "$output" ]] && cmp -s "$staging" "$output" \
    || die "output already exists with different evidence"
elif ! ln "$staging" "$output" 2>/dev/null; then
  [[ -f "$output" && ! -L "$output" ]] && cmp -s "$staging" "$output" \
    || die "output was created with different evidence"
fi
printf 'Assembled public inventory evidence %s for run %s.\n' "$output" "$run_id"
