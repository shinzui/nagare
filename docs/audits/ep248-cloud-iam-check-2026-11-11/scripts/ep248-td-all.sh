#!/usr/bin/env bash
source "$(dirname "$0")/ep248-lib.sh"
set +e
mkdir -p "$SP/evidence-keep"; cp -R "$RUN/evidence" "$SP/evidence-keep/ep248-run" 2>/dev/null
bash "$SP/ep248-td-raw.sh" </dev/null 2>&1 | cut -c1-200 | tail -n 16
NEW="$(gcloud compute images list --project "$PROJECT" --no-standard-images --filter='name~^nagare-image-' --format='value(name)' | grep -vxFf "$SP/ep248-images-before.txt")"
log "new images: [$NEW]"
for i in $NEW; do gcloud compute images delete "$i" --project "$PROJECT" --quiet 2>&1 | tail -n 1 | cut -c1-100; done
log "images now: $(gcloud compute images list --project "$PROJECT" --no-standard-images --filter='name~^nagare-image-' --format='value(name)' | tr '\n' ' ')"
log "before:     $(tr '\n' ' ' < "$SP/ep248-images-before.txt")"
bash "$SP/ep248-td-cf.sh" </dev/null 2>&1 | cut -c1-200 | tail -n 10
