#!/usr/bin/env bash
# EP-263 M4: `site deploy --contract 1` as the bounded deployer `ci` on the warm disposable
# local context ep235 (root releases/x86-work/ep235-drill6, daemon nagare-c4-amd64). The
# deployer deploys a rendered static site whose config program and build command fail if
# run: preview, saved review, apply. Then a site outside the delegation is refused with
# nothing published, and a run without --contract prints the canonical scope.
# Resumable: the delegation and the published image are reused when already accepted.
# Usage: NAGARECTL=/path/to/packaged/nagarectl confirm.sh
set -euo pipefail
: "${NAGARECTL:?the packaged candidate nagarectl}"
D="$HOME/.local/state/nagare/drills/ep263"
R="$HOME/.local/state/nagare/releases/x86-work/ep235-drill6"
M="$HOME/.local/state/nagare/drills/mp33-final"
REPO_ROOT="$HOME/Keikaku/bokuno/nagare"
CTX=ep235
for v in $(env | sed -n "s/^\(NAGARE_[A-Z_]*\|CLOUDSDK_[A-Z_]*\|PULUMI_[A-Z_]*\|KUBECONFIG\|SOPS_AGE_KEY_FILE\)=.*/\1/p"); do unset "$v"; done
export DOCKER_HOST="unix://$HOME/.colima/nagare-c4-amd64/docker.sock"
export XDG_CONFIG_HOME="$R/config" XDG_STATE_HOME="$R/state" XDG_CACHE_HOME="$R/cache"
export SOPS_AGE_KEY_FILE="$R/sops/age/keys.txt"
set -a; . "$R/images.env"; set +a
export NAGARE_LOCAL_REGISTRY_FORWARD=127.0.0.1:15513
export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$CTX.yaml"
docker start registry-forward > /dev/null  # the socat forward to the k3d registry, stopped with the VM
RUN="${RUN:-$(date -u +%Y%m%dT%H%M%S)}"
W="$D/runs/$RUN"; mkdir -p "$W"
EV="$W/evidence.tsv"; : >> "$EV"
log() { printf '%s ep263: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "ep263: FAIL: $*" >&2; exit 1; }
record() { printf '%s\t%s\n' "$1" "$2" >> "$EV"; log "$1: $2"; }
OP() { "$NAGARECTL" --context "$CTX" "$@"; }
CI() { NAGARE_DEPLOYER=ci "$NAGARECTL" --context "$CTX" "$@"; }
validate() { # schema document
  uvx --with jsonschema python -I "$D/validate.py" "$REPO_ROOT/docs/api/openapi.json" "$1" "$2" > /dev/null || fail "$2 is not a valid $1"
  record "schema.$1" "$(basename "$2") valid"
}
# The last transaction and every accepted scope revision (`inventory store status` reads head schema 1 only).
generation() { printf '%s %s' "$(OP inventory history --limit 1 --contract 1 | jq -r '.transactions[0].transaction')" "$(OP inventory status --contract 1 | jq -c '[.scopes[] | .digest] | sort' | shasum -a 256 | cut -c1-16)"; }
IMG="k3d-registry.localhost:5000/tan-nb-exp/nagare"
SRC=(--source-repository https://forge.example.test/team-a/site --source-run "https://ci.example.test/runs/ep263-$RUN")

# --- 0. the context is local and reaches a loopback cluster ---
OP context env | grep -Eqx "export NAGARE_MODE='?local'?" || fail "context $CTX is not mode=local"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
case "$server" in https://127.0.0.1:*|https://0.0.0.0:*|https://localhost:*) ;; *) fail "kubeconfig server $server is not loopback" ;; esac
[ "$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')" = k3d-nagare-local-server-0 ] || fail "unexpected kube node"
record candidate "$("$NAGARECTL" version | head -1)"
record server "$server"

# --- 1. the operator's delegation `ci`: team-a, hostnames ending -docs, static sites ---
if [ "$(OP delegation show ci --contract 1 2>/dev/null | jq -r '.state // empty')" != active ]; then
  OP delegation create ci --namespace team-a --host-suffix -docs --kinds static-site \
    --image-repository "$IMG/team-a" --team engineering --save-plan "$W/review-delegation" > "$W/delegation.plan.log" 2>&1 \
    || { tail -5 "$W/delegation.plan.log" >&2; fail "plan the delegation"; }
  OP inventory apply "$W/review-delegation" --yes > "$W/delegation.apply.log" 2>&1 || { tail -5 "$W/delegation.apply.log" >&2; fail "apply the delegation"; }
fi
record delegation "$(OP delegation show ci --contract 1 | jq -c '{name, state, revision, namespaces}')"

# --- 2. render with the real program; the deployer's checkout then holds a failing one ---
mkdir -p "$W/builder" "$W/deployer"
cp -R "$M/fixtures/docs" "$W/builder/docs"; cp -R "$M/fixtures/rogue" "$W/builder/rogue"
for site in docs rogue; do
  sed -i.orig 's|build = NoBuild dir.|build = BuildCommand "sh -c '"'"'echo EP-263: the build command ran >\&2; exit 97'"'"'" dir'"'"'|' "$W/builder/$site/nagare/Config.hs"
  grep -q 'BuildCommand' "$W/builder/$site/nagare/Config.hs" || fail "the $site fixture has no failing build command"
  ( cd "$W/builder/$site" && env -i PATH=/usr/bin:/bin "$NAGARECTL" site render -f nagare/Config.hs --out "$W/$site.json" ) > "$W/render-$site.log" 2>&1 \
    || { tail -5 "$W/render-$site.log" >&2; fail "render $site"; }
done
record rendered.build "$(jq -r '.config' "$W/docs.json" | jq -c '.build')"
cp -R "$W/builder/docs" "$W/deployer/docs"
cat > "$W/deployer/docs/nagare/Config.hs" <<'EOF'
module Main (main) where

main :: IO ()
main = error "EP-263: the deployer ran the repository's config program"
EOF
# The deployer refuses the program itself, so it never reaches the failing main.
if CI site deploy -f "$W/deployer/docs/nagare/Config.hs" -C "$W/deployer/docs" --skip-build --tag d1 \
  --image-resource publication:none/none/oci-image --dry-run > "$W/program-refusal.log" 2>&1; then
  fail "the deployer ran a config program"
fi
record deployer.program "$(tail -1 "$W/program-refusal.log")"

# --- 3. the deployer publishes the site image inside its repository ---
if [ -f "$D/docs-image" ]; then
  DOCS_IMAGE="$(cat "$D/docs-image")"
else
  CI app image-plan --archive "$M/docs-pod.tar" --destination "$IMG/team-a/docs:d1" --key ep263-docs-d1 \
    "${SRC[@]}" --source-revision 5ca1ab1e > "$W/image.log" 2>&1 || { tail -5 "$W/image.log" >&2; fail "publish the docs image"; }
  DOCS_IMAGE="$(sed -n 's/^Image resource: //p' "$W/image.log" | tail -1)"
  [ -n "$DOCS_IMAGE" ] || fail "no image resource in the publication output"
  printf '%s\n' "$DOCS_IMAGE" > "$D/docs-image"
fi
record image "$DOCS_IMAGE"
DEPLOY=(site deploy --rendered "$W/docs.json" -C "$W/deployer/docs" --skip-build --tag d1 --image-resource "$DOCS_IMAGE")

# --- 4. preview: one deploy-preview document on stdout ---
CI "${DEPLOY[@]}" "${SRC[@]}" --source 5ca1ab1e --dry-run --contract 1 > "$W/preview.json" 2> "$W/preview.err" \
  || { tail -5 "$W/preview.err" >&2; fail "preview"; }
[ "$(jq -s length "$W/preview.json")" = 1 ] || fail "the preview printed more than one document"
validate DeployPreview "$W/preview.json"
SCOPE="$(jq -r .application.scope "$W/preview.json")"
record preview "$(jq -c '{document, application, hooks}' "$W/preview.json")"
[ "$SCOPE" = standalone:site-docs ] || fail "the preview names $SCOPE"
jq -e '.application.configDigest | test("^[0-9a-f]{64}$")' "$W/preview.json" > /dev/null || fail "the preview has no configuration digest"

# --- 5. save: one saved-review document naming the previewed scope ---
CI "${DEPLOY[@]}" "${SRC[@]}" --source 5ca1ab1e --save-plan "$W/review" --contract 1 > "$W/saved.json" 2> "$W/saved.err" \
  || { tail -5 "$W/saved.err" >&2; fail "save the review"; }
[ "$(jq -s length "$W/saved.json")" = 1 ] || fail "the save printed more than one document"
validate SavedReview "$W/saved.json"
record saved "$(jq -c '{document, review, scopes}' "$W/saved.json")"
[ "$(jq -c .scopes "$W/saved.json")" = "[\"$SCOPE\"]" ] || fail "the saved review's scopes differ from the preview's scope"
REVIEW="$(jq -r .review.directory "$W/saved.json")"
[ "$REVIEW" = "$W/review" ] || fail "the saved review names $REVIEW"

# --- 6. apply what the saved review names: one transaction-outcome ---
CI inventory apply "$REVIEW" --yes --contract 1 > "$W/outcome.json" 2> "$W/outcome.err" \
  || { tail -5 "$W/outcome.err" >&2; fail "apply"; }
validate TransactionOutcome "$W/outcome.json"
record outcome "$(jq -c '{outcome, transaction}' "$W/outcome.json")"
[ "$(jq -r .outcome "$W/outcome.json")" = converged ] || fail "the apply did not converge"

# --- 7. the accepted scope agrees with the preview ---
OP inventory status --scope "$SCOPE" --contract 1 > "$W/status.json" || fail "read the accepted scope"
ACCEPTED="$(jq -r --arg s "$SCOPE" '.scopes[] | select(.scope == $s) | .digest' "$W/status.json")"
[ -f "$REVIEW/scopes/$ACCEPTED.json" ] || fail "the accepted revision $ACCEPTED is not the reviewed scope document"
record accepted "$(jq -c '{configDigest, overrides}' "$REVIEW/scopes/$ACCEPTED.json")"
[ "$(jq -r .configDigest "$REVIEW/scopes/$ACCEPTED.json")" = "$(jq -r .application.configDigest "$W/preview.json")" ] || fail "accepted digest differs from the preview's"
[ "$(jq -c '.overrides | del(.["delegation.deployer"])' "$REVIEW/scopes/$ACCEPTED.json")" = "$(jq -c .application.overrides "$W/preview.json")" ] || fail "accepted inputs differ from the preview's"
[ "$(jq -r '.overrides["delegation.deployer"]' "$REVIEW/scopes/$ACCEPTED.json")" = ci ] || fail "the accepted scope is not the deployer's"
kubectl -n team-a wait ksvc/docs --for=condition=Ready --timeout=300s > /dev/null || fail "the site is not Ready"
record serving "$(kubectl -n team-a get ksvc docs -o jsonpath='{.status.url} {.spec.template.spec.containers[0].image}')"

# --- 8. the transaction history names the deployer and the supplied source ---
OP inventory history --limit 3 --contract 1 > "$W/history.json"
TX="$(jq -r .transaction "$W/outcome.json")"
record history "$(jq -c --arg t "$TX" '.transactions[] | select(.transaction == $t) | {transaction, actor, scopes, source, state}' "$W/history.json")"
jq -e --arg t "$TX" --arg run "${SRC[3]}" '.transactions[] | select(.transaction == $t) | .actor.kind == "deployer" and .actor.name == "ci" and .source.repository == "https://forge.example.test/team-a/site" and .source.revision == "5ca1ab1e" and .source.run == $run' "$W/history.json" > /dev/null \
  || fail "the history does not attribute the transaction to ci with its source"

# --- 9. a site outside the delegation is refused and publishes nothing ---
before="$(generation)"
rc=0
CI site deploy --rendered "$W/rogue.json" -C "$W/deployer/docs" --skip-build --tag d1 --image-resource "$DOCS_IMAGE" \
  "${SRC[@]}" --source 5ca1ab1e --save-plan "$W/review-rogue" --contract 1 > "$W/rogue.json.out" 2> "$W/rogue.err" || rc=$?
after="$(generation)"
validate TransactionOutcome "$W/rogue.json.out"
record rogue "exit $rc $(jq -c '{outcome, code: .problem.code, detail: .problem.detail}' "$W/rogue.json.out")"
[ "$rc" = 2 ] || fail "the out-of-delegation plan exited $rc"
[ "$(jq -r .outcome "$W/rogue.json.out")" = refused ] || fail "the out-of-delegation plan was not refused"
[ "$before" = "$after" ] || fail "the refused plan changed the store ($before -> $after)"
[ ! -e "$W/review-rogue/review.json" ] || fail "the refused plan saved a review"
record rogue.store "before $before after $after"

# --- 10. without --contract the dry run prints the canonical scope ---
CI "${DEPLOY[@]}" --dry-run > "$W/plain.json" 2> "$W/plain.err" || { tail -5 "$W/plain.err" >&2; fail "plain dry run"; }
record plain "$(jq -c '{scope, configDigest, overrides, version, document}' "$W/plain.json")"
jq -e '.scope == {"kind":"Standalone","name":"site-docs"} and (has("document") | not) and (has("bundles"))' "$W/plain.json" > /dev/null \
  || fail "the plain dry run is not the canonical scope"
log PASS
