#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}
archive() {
  bash "$repo_root/scripts/assemble-managed-resource-evidence.sh" \
    --release-manifest "$test_root/release.json" --system aarch64-darwin \
    --rehearsal-dir "$test_root/rehearsal" \
    --private-store-export "$test_root/private-store" \
    --coverage-result "$test_root/coverage.json" --output "$test_root/public/evidence.json"
}
expect_refusal() {
  if archive >"$test_root/refusal.out" 2>"$test_root/refusal.err"; then
    printf 'expected evidence refusal\n' >&2
    exit 1
  fi
}

mkdir -p "$test_root/rehearsal/review" "$test_root/rehearsal/no-op-review" \
  "$test_root/private-store/journal"
jq -nS '{version: "0.4.0", revision: "fixture-revision", consistent: true,
  payloadDigests: {"aarch64-darwin": "sha256-fixture-payload"}}' > "$test_root/release.json"
jq -nS '{version: "0.4.0", revision: "fixture-revision"}' \
  > "$test_root/rehearsal/operator-version.json"
jq -nS '{schemaVersion: 1, context: "fixture", mode: "local",
  expectedProject: null, expectedCluster: "fixture-cluster"}' > "$test_root/rehearsal/target.json"
jq -nS '{scopes: ["fixture"]}' > "$test_root/rehearsal/candidate.json"
candidate_digest="$(sha256_file "$test_root/rehearsal/candidate.json")"
printf '%s\n' "$candidate_digest" > "$test_root/rehearsal/candidate.sha256"
verification_digest="$(printf 'a%.0s' {1..64})"
receipt_digest="$(printf 'b%.0s' {1..64})"
jq -nS --arg candidate "$candidate_digest" \
  '{version: 1, context: {identity: "fixture", project: "project"},
    candidateDigest: $candidate, desiredRevisions: [{scope: {kind: "Platform", name: "fixture"},
      revision: {generation: 1, digest: $candidate}}], operations: [{summary: "created fixture"}]}' \
  > "$test_root/rehearsal/review/review.json"
review_digest="$(sha256_file "$test_root/rehearsal/review/review.json")"
printf '%s\n' "$review_digest" > "$test_root/rehearsal/review/review.sha256"
jq -nS --arg candidate "$candidate_digest" --arg review "$review_digest" \
  --arg verification "$verification_digest" \
  '{state: "verified", noOp: true, candidateDigest: $candidate,
    reviewDigest: $review, verificationCandidateDigest: $verification}' \
  > "$test_root/rehearsal/run.json"
jq -nS --arg verification "$verification_digest" \
  '{version: 1, candidateDigest: $verification, operations: []}' \
  > "$test_root/rehearsal/no-op-review/review.json"
jq -nS --slurpfile reviewed "$test_root/rehearsal/review/review.json" \
  '{context: $reviewed[0].context, observationComplete: true, activeTransaction: null,
    missingProviders: [], accepted: $reviewed[0].desiredRevisions,
    converged: $reviewed[0].desiredRevisions,
    findings: [{category: "in-sync", address: "private-address"}], retained: [],
    providers: [{executor: "KubernetesExecutor", identity: "fixture", version: "1"}]}' \
  > "$test_root/rehearsal/final-observation.json"
jq -nS --slurpfile final "$test_root/rehearsal/final-observation.json" \
  '{version: 1, sequence: 2, binding: $final[0].context, activeTransaction: null,
    executorClaim: null, accepted: $final[0].accepted, converged: $final[0].converged,
    privateCredential: "must-never-be-public"}' > "$test_root/private-store/head.json"
jq -nS --arg receipt "$receipt_digest" --arg transaction "tx-$review_digest" \
  '{version: 1, sequence: 0, transaction: $transaction, operation: "op-fixture", state: {tag: "Completed", contents: $receipt},
    detail: "must-never-be-public"}' > "$test_root/private-store/journal/00000000000000000000.json"
jq -nS --arg transaction "tx-$review_digest" \
  '{version: 1, sequence: 1, transaction: $transaction, operation: null,
    state: {tag: "Completed", contents: null}, detail: "converged"}' \
  > "$test_root/private-store/journal/00000000000000000001.json"
jq -nS \
  --arg head "$(sha256_file "$test_root/private-store/head.json")" \
  --arg journal "$(sha256_file "$test_root/private-store/journal/00000000000000000000.json")" \
  --arg completion "$(sha256_file "$test_root/private-store/journal/00000000000000000001.json")" \
  '{version: 1, members: [{path: "head.json", digest: $head},
    {path: "journal/00000000000000000000.json", digest: $journal},
    {path: "journal/00000000000000000001.json", digest: $completion}]}' \
  > "$test_root/private-store/backup.json"
jq -nS '{schemaVersion: 1, complete: true, auditedCommands: 1,
  privateNote: "must-never-be-public"}' > "$test_root/coverage.json"

archive
jq -e --arg candidate "$candidate_digest" --arg review "$review_digest" \
  '.schemaVersion == 1 and .inventoryDigest == $candidate
    and .reviewedChangeDigest == $review and (.run.id | length == 64)' \
  "$test_root/public/evidence.json" >/dev/null
jq -e '.componentReceipts | length == 1' "$test_root/public/evidence.json" >/dev/null
if grep -q 'must-never-be-public\|private-address' "$test_root/public/evidence.json"; then
  printf 'private evidence leaked into public manifest\n' >&2
  exit 1
fi
archive

jq -nS '{schemaVersion: 1, complete: false}' > "$test_root/coverage.json"
expect_refusal
jq -nS '{schemaVersion: 1, complete: true}' > "$test_root/coverage.json"
printf '\n' >> "$test_root/private-store/journal/00000000000000000000.json"
expect_refusal
printf 'managed-resource evidence tests passed\n'
