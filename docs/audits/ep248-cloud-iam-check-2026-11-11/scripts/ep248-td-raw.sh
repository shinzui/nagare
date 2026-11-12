#!/usr/bin/env bash
source "$(dirname "$0")/ep248-lib.sh"
P0="$PATH"; eval "$(N context env)"; export PATH="$P0"
W="$(N platform root --json | jq -er .workspaceRoot)/infra/pulumi"
[ "$CLOUDSDK_CORE_PROJECT" = tan-nb-exp ] && [ "$NAGARE_PULUMI_STACK" = ep248 ] || die "wrong target"
case "$PULUMI_BACKEND_URL" in "file://$RUN/"*) ;; *) die "backend is not this run's local state" ;; esac
log "backend is the run's local state; stack ep248"
pulumi -C "$W" config set nagare:vmDeletionProtection false --stack ep248
URN="$(pulumi -C "$W" stack export --stack ep248 --show-secrets=false | jq -r '.deployment.resources[] | select(.type=="gcp:compute/instance:Instance") | .urn')"
log "instance urn ends: ${URN##*::}"
[ "${URN##*::}" = ep248-01 ] || die "unexpected instance"
pulumi -C "$W" preview --stack ep248 --target "$URN" --json 2>/dev/null | jq -r '[.steps[]|select(.op!="same")|"\(.op) \(.urn|split("::")|last)"]|join("; ")'
pulumi -C "$W" up --stack ep248 --target "$URN" --yes --skip-preview --non-interactive --color=never 2>&1 | tail -n 3 | cut -c1-120
log "deletion protection now: $(gcloud compute instances describe ep248-01 --project "$PROJECT" --zone us-west1-a --format='value(deletionProtection)')"
pulumi -C "$W" state unprotect --all --yes --stack ep248 2>&1 | tail -n 1 | cut -c1-100
gcloud storage rm --recursive --all-versions "gs://tan-nb-exp-ep248-state/**" >/dev/null 2>&1 || true
for b in tan-nb-exp-ep248-images tan-nb-exp-ep248-backups; do gcloud storage rm --recursive --all-versions "gs://$b/**" >/dev/null 2>&1 || true; done
pulumi -C "$W" destroy --stack ep248 --preview-only --json --non-interactive 2>/dev/null > "$RUN/evidence/destroy-preview.json" || true
jq -r '[.steps[].op]|group_by(.)|map("\(.[0]) \(length)")|join(", ")' "$RUN/evidence/destroy-preview.json"
bad="$(jq -r '[.steps[]|select(.op!="delete" and .op!="same" and .op!="discard")]|length' "$RUN/evidence/destroy-preview.json")"
[ "$bad" = 0 ] || die "destroy preview holds something other than deletes"
foreign="$(jq -r '[.steps[]|select(.urn|startswith("urn:pulumi:ep248::nagare::")|not)]|length' "$RUN/evidence/destroy-preview.json")"
[ "$foreign" = 0 ] || die "destroy preview names a resource outside the stack"
log "destroying"
pulumi -C "$W" destroy --stack ep248 --yes --skip-preview --non-interactive --color=never > "$RUN/evidence/pulumi-destroy.log" 2>&1 || { tail -n 15 "$RUN/evidence/pulumi-destroy.log" | cut -c1-220 >&2; die "destroy did not finish"; }
tail -n 4 "$RUN/evidence/pulumi-destroy.log" | cut -c1-110
left="$(pulumi -C "$W" stack export --stack ep248 --show-secrets=false | jq -r '[.deployment.resources[]? | select(.type != "pulumi:pulumi:Stack")] | length')"
log "resources left in the stack: $left"
[ "$left" = 0 ] || die "teardown left resources"
g() { gcloud "$@" --project "$PROJECT" 2>/dev/null; }
echo "instances: $(g compute instances list --format='value(name,status)' | sort | tr '\t' '=' | tr '\n' ' ')"
echo "ep248 names: sa=[$(g iam service-accounts list --filter='email:ep248-node@*' --format='value(email)')] repo=[$(g artifacts repositories list --location us-west1 --format='value(name)' | grep -x ep248 || true)] buckets=[$(gcloud storage ls --project "$PROJECT" 2>/dev/null | grep ep248 || true)]"
echo "networks: $(g compute networks list --format='value(name)' | sort | tr '\n' ' ')"
echo "dns: $(g dns managed-zones list --format='value(name,dnsName)' | tr '\t' '=' | tr '\n' ' ')"
echo "addresses: $(g compute addresses list --format='value(name)' | tr '\n' ' ')"
echo "images: $(g compute images list --no-standard-images --filter='name~^nagare-image-' --format='value(name)' | tr '\n' ' ')"
echo "disks ep248: $(g compute disks list --filter='name~ep248' --format='value(name)' | tr '\n' ' ')"
