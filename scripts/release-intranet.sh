#!/usr/bin/env bash
# EP-210 M5: move the intranet to a release candidate, or pin it to the published tag
# (docs/runbooks/releases.md). `just release-candidate` runs the first form after assembly and
# `just release-publish` the second after the public flake check; both run unattended under the
# operator's standing go-ahead (EP-210 Decision Log, 2026-10-20).
#
#   scripts/release-intranet.sh VERSION [--run DIR]             the candidate
#   scripts/release-intranet.sh VERSION [--run DIR] --pin-tag   the published tag
#
# The candidate form pins the operator repository's Nagare input to the run's revision, plans and
# applies the platform transition until a plan has no operations, commits it, and requires an
# exact platform status, a converged inventory and the protected URL answering 302 to its login
# page. Only then does it commit the pin files, by path, and write <run>/intranet.json, which
# release-publish requires. It never edits app config: an operator config the candidate does not
# compile stops the plan with the compiler's message, and the fix is the operator's. Every step
# stops at its first refusal; an apply that stops ambiguous is resumed once by transaction id.
#
# The operator repository is NAGARE_RELEASE_OPERATOR_REPO (default: Mori's path for
# mori://tan/tan-ng-labs), its context NAGARE_RELEASE_CONTEXT (default intranet), and nagarectl
# runs through that repository's dev shell (direnv exec) from an empty environment, so nothing
# from the calling shell's context reaches it.
set -euo pipefail

usage() { echo "usage: $0 VERSION [--run DIR] [--pin-tag]" >&2; exit 2; }
die() { printf 'release-intranet: %s\n' "$*" >&2; exit 1; }
step() { printf '%s release-intranet: %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

[[ $# -ge 1 ]] || usage
version="$1"
shift
run=""
pin_tag=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) [[ $# -ge 2 ]] || usage; run="$2"; shift 2 ;;
    --pin-tag) pin_tag=true; shift ;;
    *) usage ;;
  esac
done
tag="v$version"
run="${run:-${XDG_STATE_HOME:-$HOME/.local/state}/nagare/releases/$tag/latest}"
[[ -f "$run/candidate.json" ]] || die "no candidate run at $run"
run="$(cd "$run" && pwd -P)"
[[ "$(jq -er .version "$run/candidate.json")" == "$version" ]] || die "$run is not a run for $version"
rev="$(jq -er .revision "$run/candidate.json")"
context="${NAGARE_RELEASE_CONTEXT:-intranet}"
operator="${NAGARE_RELEASE_OPERATOR_REPO:-$(mori path mori://tan/tan-ng-labs 2>/dev/null | tail -1)}"
[[ -n "$operator" && -d "$operator/.git" ]] || die "no operator repository at '$operator'; set NAGARE_RELEASE_OPERATOR_REPO"
stages_max=12

# An empty environment, as a fresh operator shell has: the calling shell may carry another
# context's NAGARE_*, CLOUDSDK_* and KUBECONFIG from its own direnv.
clean() {
  local keep=(HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" TMPDIR="${TMPDIR:-/tmp}" PATH="$PATH" TERM="${TERM:-dumb}")
  local name
  for name in SSH_AUTH_SOCK XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME; do
    [[ -z "${!name:-}" ]] || keep+=("$name=${!name}")
  done
  env -i "${keep[@]}" "$@"
}
N() { clean direnv exec "$operator" nagarectl --context "$context" "$@"; }
G() { git -C "$operator" "$@"; }

# Point inputs.nagare.url at REF and lock it; the lock must resolve to the candidate.
pin() { # ref
  local ref="$1"
  sed -i.bak -E "s|^([[:space:]]*inputs\.nagare\.url = \")[^\"]*(\";)|\1github:shinzui/nagare/$ref\2|" "$operator/flake.nix"
  rm -f "$operator/flake.nix.bak"
  grep -Fq "inputs.nagare.url = \"github:shinzui/nagare/$ref\";" "$operator/flake.nix" \
    || die "$operator/flake.nix has no inputs.nagare.url line to pin"
  (cd "$operator" && clean nix flake update nagare) >/dev/null
  [[ "$(jq -r .nodes.nagare.locked.rev "$operator/flake.lock")" == "$rev" ]] \
    || die "the operator flake.lock does not resolve github:shinzui/nagare/$ref to $rev"
}

# Commit exactly the changed pin files; nothing else the operator has staged goes with them.
commit_pins() { # subject body files...
  local subject="$1" body="$2" changed=() file
  shift 2
  for file in "$@"; do
    [[ -z "$(G status --porcelain -- "$file")" ]] || changed+=("$file")
  done
  if [[ ${#changed[@]} -eq 0 ]]; then
    step "the operator repository already records this pin"
    return
  fi
  G add -- "${changed[@]}"
  G commit -q -m "$subject" -m "$body" --only -- "${changed[@]}"
  step "committed $(G rev-parse --short HEAD) in $operator: ${changed[*]}"
}

pins=(flake.nix flake.lock "hosts/$context/flake.nix" "hosts/$context/flake.lock" "contexts/$context.env")
tracked=()
for file in "${pins[@]}"; do
  G ls-files --error-unmatch -- "$file" >/dev/null 2>&1 && tracked+=("$file")
done
[[ " ${tracked[*]} " == *" flake.nix "* ]] || die "$operator does not track flake.nix"

# --- the published tag: the same commit, named by its tag ---
if $pin_tag; then
  [[ -z "$(G status --porcelain -- flake.nix flake.lock)" ]] || die "flake.nix or flake.lock has uncommitted changes in $operator"
  pin "$tag"
  commit_pins "chore(nagare): pin the $context to the published $tag tag" \
    "$tag is the candidate $rev the $context already runs." flake.nix flake.lock
  exit 0
fi

# --- preflight: refuse before changing anything ---
[[ -z "$(G status --porcelain -- "${tracked[@]}")" ]] \
  || die "the pin files have uncommitted changes in $operator: $(G status --porcelain -- "${tracked[@]}" | tr '\n' ' ')"
clean direnv exec "$operator" sh -c 'command -v gcloud' >/dev/null || die "gcloud is not on PATH"
protected="${NAGARE_RELEASE_PROTECTED_URL:-https://protected-hello.$(clean direnv exec "$operator" printenv NAGARE_BASE_DOMAIN)/}"
reviews="$run/intranet"
mkdir -p "$reviews"

# --- 1. pin the candidate; the dev shell then carries its nagarectl ---
step "pinning $operator to $rev"
pin "$rev"
N version --json | jq -e --arg v "$version" --arg r "$rev" '.version == $v and .revision == $r' >/dev/null \
  || die "the operator shell's nagarectl is not $version at $rev"
N inventory status --json | jq -e '.activeTransaction == null' >/dev/null \
  || die "the $context store has an active transaction; resume or close it with the release that opened it"

# --- 2. plan and apply until a plan has no operations, then commit the transition ---
operations() { jq '.operations | length' "$1/review.json"; }
# A transition re-declares every scope from the target payload; a review that only re-accepts
# declarations is applied too. The bootstrap stamp is re-accepted on every replan and does not count.
reaccepts() {
  jq '([.baseRevisions[] | {key: (.scope | tojson), value: .revision}] | from_entries) as $base
    | [.desiredRevisions[] | select(.scope.name != "bootstrap-stamp" and $base[.scope | tojson] != .revision)] | length' \
    "$1/review.json"
}
converged=false
for n in $(seq 1 "$stages_max"); do
  review="$reviews/stage-$n"
  rm -rf "$review"
  N platform transition plan --out "$review" > "$review.plan.log" 2>&1 \
    || die "plan $n refused: $(tail -5 "$review.plan.log")"
  ops="$(operations "$review")"
  moves="$(reaccepts "$review")"
  step "stage $n: $ops operations, re-accepts $moves scopes"
  if [[ "$ops" == 0 && "$moves" == 0 ]]; then converged=true; break; fi
  if ! N inventory apply "$review" --yes > "$review.apply.log" 2>&1; then
    tx="$(sed -n 's/^ambiguous \(tx-[0-9a-f]*\) at .*/\1/p' "$review.apply.log" | tail -1)"
    [[ -n "$tx" ]] || die "apply $n failed: $(tail -5 "$review.apply.log")"
    step "apply $n stopped ambiguous; resuming $tx once"
    N inventory resume "$tx" --yes >> "$review.apply.log" 2>&1 || die "resume of $tx failed: $(tail -5 "$review.apply.log")"
  fi
done
$converged || die "the transition did not converge in $stages_max stages; reviews in $reviews"
status="$(N platform status --json)"
if ! jq -e --arg v "$version" '.identities.context.version == $v' <<<"$status" >/dev/null; then
  step "committing the transition"
  N platform transition commit --yes > "$reviews/commit.log" 2>&1 || die "transition commit refused: $(tail -5 "$reviews/commit.log")"
  status="$(N platform status --json)"
fi

# --- 3. the checks the record stands for ---
jq -e --arg v "$version" --arg r "$rev" '
  .compatibility == "exact"
    and (.identities | [.cli, .payload, .host, .cluster] | all(.version == $v and .revision == $r))
    and .identities.context.version == $v' <<<"$status" >/dev/null \
  || die "platform status is not exact on $version at $rev: $(jq -c '{compatibility, identities}' <<<"$status")"
inventory="$(N inventory status --json)"
jq -e '.activeTransaction == null
  and ((.converged // []) as $c | (.accepted // []) | all(. as $a | $c | any(. == $a)))' <<<"$inventory" >/dev/null \
  || die "the $context inventory has an active transaction or an accepted scope that has not converged"
read -r code location < <(curl -sS -o /dev/null -m 30 -w '%{http_code} %{redirect_url}\n' "$protected") || true
[[ "${code:-}" == 302 && "${location:-}" =~ ^https?://[^/]+/[^?#]*login ]] \
  || die "$protected answered ${code:-nothing} ${location:-}, not a 302 to a login page"

# --- 4. the pin commit, then the record ---
commit_pins "feat(nagare): upgrade the $context to the $tag candidate" \
  "Moved the $context to Nagare $version at $rev with just release-candidate: platform status is exact, every accepted scope has converged, and $protected redirects to the login page." \
  "${tracked[@]}"
jq -n -S --arg version "$version" --arg revision "$rev" --arg context "$context" \
  --arg checkedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson status "$status" --argjson inventory "$inventory" \
  --arg url "$protected" --arg code "$code" --arg location "$location" \
  '{version: $version, revision: $revision, context: $context, checkedAt: $checkedAt, status: $status,
    inventory: {activeTransaction: $inventory.activeTransaction, accepted: ($inventory.accepted // [] | length), converged: true},
    protected: {url: $url, status: ($code | tonumber), location: $location}}' > "$run/intranet.json.tmp"
mv "$run/intranet.json.tmp" "$run/intranet.json"
step "the $context runs $version at $rev; record $run/intranet.json"
