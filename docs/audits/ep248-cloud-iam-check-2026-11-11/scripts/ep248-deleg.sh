#!/usr/bin/env bash
# Create the ep248ci delegation and apply it.
source "$(dirname "$0")/ep248-lib.sh"
d="$RUN/reviews/delegation-create"; rm -rf "$d"
N delegation create ep248ci --namespace team-a --host-suffix -docs --kinds static-site --kinds web-app \
  --image-repository us-west1-docker.pkg.dev/tan-nb-exp/ep248-deploy/team-a --team engineering \
  --save-plan "$d" > "$RUN/evidence/delegation-create.log" 2>&1 || { tail -n 12 "$RUN/evidence/delegation-create.log" | cut -c1-220 >&2; die "delegation create refused"; }
log "delegation review: $(jq '.operations|length' "$d/review.json") operations"
N inventory apply "$d" --yes >> "$RUN/evidence/delegation-create.log" 2>&1 || { tail -n 12 "$RUN/evidence/delegation-create.log" | cut -c1-220 >&2; die "delegation apply did not converge"; }
tail -n 1 "$RUN/evidence/delegation-create.log" | cut -c1-120
N delegation show ep248ci --contract 1 | jq -c '{name,state,namespaces,imageRepository,revision: .acceptedRevision}' | cut -c1-240
