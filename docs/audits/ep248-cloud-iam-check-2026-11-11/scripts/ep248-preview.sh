#!/usr/bin/env bash
source "$(dirname "$0")/ep248-lib.sh"
P0="$PATH"; eval "$(N context env)"; export PATH="$P0"
W="$(N platform root --json | jq -er .workspaceRoot)/infra/pulumi"
grep -E 'nagare:ingress|nagare:baseDomain' "$OPS/pulumi/Pulumi.$CTX.yaml" | cut -c1-70
pulumi -C "$W" preview --stack "$CTX" --diff=false --json > "$RUN/evidence/preview-$1.json" 2> "$RUN/evidence/preview-$1.err" || { tail -n 15 "$RUN/evidence/preview-$1.err" | cut -c1-220 >&2; die "preview failed"; }
jq -r '[.steps[].op]|group_by(.)|map("\(.[0]) \(length)")|join(", ")' "$RUN/evidence/preview-$1.json"
jq -r '.steps[]|select(.op!="same")|"\(.op)\t\(.newState.type // .oldState.type)\t\(.urn|split("::")|last)"' "$RUN/evidence/preview-$1.json" | cut -c1-100
jq -e '[.steps[]|select(.op|test("update|replace|delete"))]|length==0' "$RUN/evidence/preview-$1.json" >/dev/null || die "the preview holds an update, replace or delete"
if jq -r '.steps[].urn' "$RUN/evidence/preview-$1.json" | grep -E 'fw-web|fw-lb|fw-tailscale|nagare-zone|nagare-wildcard|nagare-apex|iam-dns'; then die "the perimeter declares a web rule or Cloud DNS"; fi
log "threshold met"
