#!/usr/bin/env bash
# Every stage of the context in order. Stops at a delete, an unexpected cloud change, a refusal or an unresolved apply.
source "$(dirname "$0")/ep248-lib.sh"
TOKEN="$OPS/cluster-secrets/$CTX/cloudflare-tunnel-token.yaml"
n="$1"
while [ "$n" -le 60 ]; do
  review="$RUN/reviews/s$n"; j="$review/review.json"
  [ -f "$j" ] || bash "$SP/ep248-plan.sh" "$n"
  ops="$(jq '.operations|length' "$j")"
  moved="$(jq '[.baseRevisions as $b | .desiredRevisions[] | . as $d | select(($b|map(select(.scope==$d.scope))|.[0].revision.digest) != $d.revision.digest)]|length' "$j")"
  if [ "$ops" = 0 ] && [ "$moved" = 0 ]; then log "converged at $n: a review with no operations"; exit 0; fi
  jq -e '[.operations[]|(.operation//.)|.action.tag]|any(test("Delete|Retire|Replace"))' "$j" >/dev/null && die "stage $n holds a delete, retire or replace"
  zone=0
  if jq -e '.desiredRevisions|any(.scope.name=="cloudflare-zone")' "$j" >/dev/null && ! jq -e '.baseRevisions|any(.scope.name=="cloudflare-zone")' "$j" >/dev/null; then
    zone=1
    [ "$ops" = 12 ] || die "the zone stage holds $ops operations, not the reviewed 12"
    jq -r '.operations[].operation.resources[]' "$j" | grep -qv '^platform:cloudflare-zone/' && die "the zone stage names another scope"
    jq -r '.operations[].summary' "$j" > "$RUN/evidence/zone-stage.txt"
  fi
  host=0; jq -e '[.operations[]|(.operation//.)|(.executor//.plannedExecutor)]|any(.=="HostExecutor")' "$j" >/dev/null && host=1
  if jq -e '[.operations[]|(.operation//.)|(.executor//.plannedExecutor)]|any(.=="PulumiExecutor")' "$j" >/dev/null; then bash "$SP/ep248-preview.sh" "s$n" | tail -n 4 | cut -c1-110; fi
  if ! bash "$SP/ep248-apply.sh" "$n"; then
    [ "$host" = 1 ] || die "stage $n failed"
    bash "$SP/ep248-sign.sh" || die "stage $n failed and signing did not help"
    tx="$(N inventory status --json 2>/dev/null | jq -r .activeTransaction)"
    [ "$tx" != null ] || die "the host stage stopped with no active transaction"
    N inventory resume "$tx" --yes >> "$review.apply.log" 2>&1 || { tail -n 6 "$review.apply.log" | cut -c1-220 >&2; die "the host stage did not resume after signing"; }
    log "host stage converged after signing exactly this node"
    C="$XDG_CONFIG_HOME/nagare/pulumi/Pulumi.$CTX.yaml"; if [ -f "$C" ] && [ ! -L "$C" ]; then mv "$C" "$OPS/pulumi/Pulumi.$CTX.yaml"; ln -s "$OPS/pulumi/Pulumi.$CTX.yaml" "$C"; fi
  fi
  if [ "$zone" = 1 ]; then
    N tunnel token > "$RUN/evidence/tunnel-token.log" 2>&1 || { cut -c1-200 "$RUN/evidence/tunnel-token.log" >&2; die "tunnel token refused"; }
    grep -q '^sops:' "$TOKEN" && grep -q 'ENC\[' "$TOKEN" || die "the token file is not sops-encrypted"
    log "tunnel token saved, sops-encrypted"
  fi
  n=$((n+1))
done
die "did not converge within the stage cap"
