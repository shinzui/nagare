#!/usr/bin/env bash
# Refuse an expensive inventory operation unless its installed CLI, accepted
# payload workspace, context, and shared history match the reviewed checkpoint.
set -euo pipefail

if [[ $# -ne 9 ]]; then
  echo "usage: $0 CLI PAYLOAD_ROOT CONTEXT PROJECT CLI_REVISION PAYLOAD_ID PAYLOAD_DIGEST HEAD_GENERATION HEAD_DIGEST" >&2
  exit 2
fi

candidate=$1
payload_root=$2
context=$3
project=$4
cli_revision=$5
payload_id=$6
payload_digest=$7
head_generation=$8
head_digest=$9

fail() {
  echo "inventory candidate preflight: $*" >&2
  exit 1
}

[[ -x "$candidate" ]] || fail "candidate CLI is not executable"
[[ -d "$payload_root" && -f "$payload_root/.nagare-workspace.json" ]] ||
  fail "accepted payload workspace is absent"
[[ "$head_generation" =~ ^[0-9]+$ ]] || fail "head generation is invalid"

jq -e --arg id "$payload_id" --arg digest "$payload_digest" \
  '.payloadId == $id and .digest == $digest' \
  "$payload_root/.nagare-workspace.json" >/dev/null ||
  fail "payload workspace identity differs from the accepted payload"

version=$(NAGARE_PLATFORM_ROOT="$payload_root" "$candidate" version --json) ||
  fail "candidate version check failed"
jq -e --arg revision "$cli_revision" '.revision == $revision' \
  <<<"$version" >/dev/null || fail "candidate CLI revision differs"

# This local check validates the payload's actual asset digest and workspace
# binding before the shared-store read. It does not contact a provider.
root=$(NAGARE_PLATFORM_ROOT="$payload_root" "$candidate" --context "$context" platform root --json) ||
  fail "candidate cannot validate its accepted payload workspace"
jq -e --arg root "$payload_root" --arg id "$payload_id" \
  --arg digest "$payload_digest" \
  '.workspaceRoot == $root and .payloadId == $id and .digest == $digest' \
  <<<"$root" >/dev/null || fail "payload assets or workspace binding differ"

status=$(NAGARE_PLATFORM_ROOT="$payload_root" "$candidate" \
  --context "$context" inventory store status --json) ||
  fail "shared-store status failed"
jq -e --arg context "$context" --arg project "$project" \
  --argjson generation "$head_generation" --arg digest "$head_digest" \
  '.binding.identity == $context and .binding.project == $project
   and .generation == $generation and .headDigest == $digest
   and .activeTransaction == null and .executorClaim == null
   and .dataFence == null and .migration == null' \
  <<<"$status" >/dev/null || fail "shared head differs or is not idle"

echo "candidate, accepted payload, and idle shared head match"
