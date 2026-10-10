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
  local expected="$1"
  if archive >"$test_root/refusal.out" 2>"$test_root/refusal.err"; then
    printf 'expected evidence refusal\n' >&2
    exit 1
  fi
  if ! grep -q "$expected" "$test_root/refusal.err"; then
    printf 'unexpected evidence refusal: %s\n' "$(cat "$test_root/refusal.err")" >&2
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
scope_digest="$(printf 'c%.0s' {1..64})"
# Real nagarectl shapes (F42): the compiled candidate lists desired scope
# digests and generations; a review's candidateDigest is the planner's own
# proposal digest and never the candidate manifest's digest.
jq -nS --arg scope "$scope_digest" \
  '{version: 1, desired: {context: {identity: "fixture"}, scopes: [{scope: {kind: "Platform", name: "fixture"},
      member: ("scopes/" + $scope + ".json"), digest: $scope}]},
    generations: [{scope: {kind: "Platform", name: "fixture"}, generation: 1}]}' \
  > "$test_root/rehearsal/candidate.json"
candidate_digest="$(sha256_file "$test_root/rehearsal/candidate.json")"
printf '%s\n' "$candidate_digest" > "$test_root/rehearsal/candidate.sha256"
verification_digest="$(printf 'a%.0s' {1..64})"
receipt_digest="$(printf 'b%.0s' {1..64})"
jq -nS --arg scope "$scope_digest" --arg proposal "$(printf 'd%.0s' {1..64})" \
  '{version: 1, context: {identity: "fixture", project: "project"},
    candidateDigest: $proposal, desiredRevisions: [{scope: {kind: "Platform", name: "fixture"},
      revision: {generation: 1, digest: $scope}}],
    operations: [{operation: {id: "op-fixture"}, summary: "created fixture"}]}' \
  > "$test_root/rehearsal/review/review.json"
review_digest="$(sha256_file "$test_root/rehearsal/review/review.json")"
printf '%s\n' "$review_digest" > "$test_root/rehearsal/review/review.sha256"
jq -nS --arg candidate "$candidate_digest" --arg review "$review_digest" \
  --arg verification "$verification_digest" \
  '{state: "verified", noOp: true, candidateDigest: $candidate,
    reviewDigest: $review, verificationCandidateDigest: $verification}' \
  > "$test_root/rehearsal/run.json"
jq -nS --arg scope "$scope_digest" --arg proposal "$(printf 'e%.0s' {1..64})" \
  '{version: 1, candidateDigest: $proposal, operations: [],
    desiredRevisions: [{scope: {kind: "Platform", name: "fixture"}, revision: {generation: 2, digest: $scope}}]}' \
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
jq -nS --arg digest "$candidate_digest" '{schemaVersion: 1, complete: true,
  sourceRevision: "fixture-revision", candidateDigest: $digest, dirty: false,
  registeredRoutes: 1, recipes: 1, libraryCalls: 1,
  deferredRoutes: [
    "DbCommand.DbRestore.--into-live", "DbCommand.DbShell",
    "StorageCommand.StorageRestore.--into-live"],
  recoveryOnlyRoutes: ["DbCommand.DbRecoverScheduledPrune"],
  pending: [], pendingRecipes: [], incompleteCatalogueRows: [], errors: [],
  privateNote: "must-never-be-public"}' > "$test_root/coverage.json"
cp "$test_root/coverage.json" "$test_root/coverage-complete.json"

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
expect_refusal 'mutation coverage is incomplete'
cp "$test_root/coverage-complete.json" "$test_root/coverage.json"
jq -S 'del(.deferredRoutes)' "$test_root/coverage.json" > "$test_root/coverage-changed.json"
mv "$test_root/coverage-changed.json" "$test_root/coverage.json"
expect_refusal 'mutation coverage is incomplete'
cp "$test_root/coverage-complete.json" "$test_root/coverage.json"
jq -S '.sourceRevision = "another-revision"' "$test_root/coverage.json" \
  > "$test_root/coverage-changed.json"
mv "$test_root/coverage-changed.json" "$test_root/coverage.json"
expect_refusal 'mutation coverage belongs to another source revision'
cp "$test_root/coverage-complete.json" "$test_root/coverage.json"
sed 's/op-fixture/op-other/' "$test_root/private-store/journal/00000000000000000000.json" \
  > "$test_root/private-store/journal/changed.json"
mv "$test_root/private-store/journal/changed.json" \
  "$test_root/private-store/journal/00000000000000000000.json"
jq -S --arg digest "$(sha256_file "$test_root/private-store/journal/00000000000000000000.json")" \
  '.members |= map(if .path == "journal/00000000000000000000.json" then .digest = $digest else . end)' \
  "$test_root/private-store/backup.json" > "$test_root/private-store/changed.json"
mv "$test_root/private-store/changed.json" "$test_root/private-store/backup.json"
expect_refusal 'completed component receipts do not match the reviewed operations'
printf '\n' >> "$test_root/private-store/journal/00000000000000000000.json"
expect_refusal 'private export member changed'

# F42: each review is bound through desired scope revisions, with distinct
# refusals for an unbound review, an empty initial review and a changed replan.
reviewed="$test_root/rehearsal/review/review.json"
cp "$reviewed" "$test_root/review-good.json"
rebind() { sha256_file "$reviewed" > "$test_root/rehearsal/review/review.sha256"
  jq -S --arg review "$(sha256_file "$reviewed")" '.reviewDigest = $review' "$test_root/rehearsal/run.json" > "$test_root/run.tmp"
  mv "$test_root/run.tmp" "$test_root/rehearsal/run.json"; }
jq -S '.desiredRevisions[0].revision.digest = "'"$(printf 'f%.0s' {1..64})"'"' "$test_root/review-good.json" > "$reviewed"; rebind
expect_refusal "initial review is not bound to the candidate's desired scope revisions"
jq -S '.operations = []' "$test_root/review-good.json" > "$reviewed"; rebind
expect_refusal 'initial review has no operations'
cp "$test_root/review-good.json" "$reviewed"; rebind
noop="$test_root/rehearsal/no-op-review/review.json"; cp "$noop" "$test_root/noop-good.json"
jq -S '.operations = [{summary: "late change"}]' "$test_root/noop-good.json" > "$noop"
expect_refusal 'fresh review has operations'
jq -S '.desiredRevisions[0].revision.digest = "'"$(printf 'f%.0s' {1..64})"'"' "$test_root/noop-good.json" > "$noop"
expect_refusal 'fresh review is not bound to the accepted revisions it replans'
cp "$test_root/noop-good.json" "$noop"

# Real CLI output from the 14071e58 runner rehearsal: both reviews bind, and
# its incomplete final observation (AccessExecutor unobserved) still refuses.
real="$repo_root/fixtures/managed-resource-evidence/c2-14071e58-runner"
rm -rf "$test_root/rehearsal"; mkdir -p "$test_root/rehearsal"
cp -R "$real/." "$test_root/rehearsal/"; rm -f "$test_root/rehearsal/README.md"
jq -S '.version = "0.4.0" | .revision = "fixture-revision"' "$real/operator-version.json" > "$test_root/rehearsal/operator-version.json"
expect_refusal 'final observation is incomplete or diverged'
jq -S '.desiredRevisions[0].revision.digest = "'"$(printf 'f%.0s' {1..64})"'"' "$real/review/review.json" > "$test_root/rehearsal/review/review.json"
sha256_file "$test_root/rehearsal/review/review.json" > "$test_root/rehearsal/review/review.sha256"
jq -S --arg review "$(sha256_file "$test_root/rehearsal/review/review.json")" '.reviewDigest = $review' "$real/run.json" > "$test_root/rehearsal/run.json"
expect_refusal "initial review is not bound to the candidate's desired scope revisions"
printf 'managed-resource evidence tests passed\n'
