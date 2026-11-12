#!/usr/bin/env bash
# EP-248 D6: what the cloud lets a delegated deployer do with only its bundle key.
# Usage: ep248-iam.sh BUNDLE LABEL [MODE]
#   MODE=active  (default) the full allow/deny matrix
#   MODE=refused every request must be refused (revoked or rotated key)
source "$(dirname "$0")/ep248-lib.sh"
set +e
B="$1"; label="$2"; mode="${3:-active}"
BKT=tan-nb-exp-ep248-state
PFX="inventory"
OTHER_BKT=tan-nb-exp-nagare-pulumi-state
REGION=us-west1
DEP_REPO="$REGION-docker.pkg.dev/$PROJECT/ep248-deploy/team-a"
PLAT_REPO="$REGION-docker.pkg.dev/$PROJECT/ep248"
out="$RUN/evidence/iam-$label.txt"; : > "$out"
pass=0; fail=0
# The deployer's own environment: nothing of the operator's gcloud, only the bundle.
D() {
  env -i HOME="$B" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" \
    CLOUDSDK_CONFIG="$B/.config/gcloud" \
    CLOUDSDK_CORE_DISABLE_PROMPTS=1 "$@"
}
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" | tee -a "$out" | cut -c1-200; }
# expect allow|deny, name, command...
check() {
  local expect="$1" name="$2"; shift 2
  local err rc
  err="$(D "$@" 2>&1 >/dev/null)"; rc=$?
  local got
  if [ "$rc" = 0 ] && printf '%s' "$err" | grep -qE "Required '[a-z.]+' permission"; then got=deny
  elif [ "$rc" = 0 ]; then got=allow
  elif printf '%s' "$err" | grep -qiE '403|PERMISSION_DENIED|does not have|denied|forbidden|not authorized|disabled|invalid_grant|account not found|401|UNAUTHENTICATED'; then got=deny
  else got="error"; fi
  if [ "$got" = "$expect" ]; then pass=$((pass+1)); record PASS "$name" "$got" "$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-140)"
  else fail=$((fail+1)); record FAIL "$name" "expected $expect, got $got" "$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-200)"; fi
}
[ -s "$B/.config/gcloud/deployer-key.json" ] || die "no key in $B"
log "identity: $(jq -r .client_email "$B/.config/gcloud/deployer-key.json")"
other="$(gcloud storage ls "gs://$OTHER_BKT/nagare/tan-nb-exp/**" --project "$PROJECT" 2>/dev/null | head -n 1)"
[ -n "$other" ] || die "no foreign object to probe"
# An operator-written object in the same bucket, outside the inventory prefix.
beside="gs://$BKT/outside/operator-object.txt"
printf 'operator\n' | gcloud storage cp - "$beside" --project "$PROJECT" >/dev/null 2>&1 || die "could not write the beside object"
probe="iam-probe-$label-$(date -u +%H%M%S)"
printf 'probe\n' > "$RUN/evidence/$probe"
if [ "$mode" = refused ]; then
  check deny "read own head" gcloud storage cat "gs://$BKT/$PFX/head.json"
  check deny "write own prefix" gcloud storage cp "$RUN/evidence/$probe" "gs://$BKT/$PFX/$probe"
  check deny "list bucket" gcloud storage ls "gs://$BKT/$PFX/"
else
  check allow "read own head" gcloud storage cat "gs://$BKT/$PFX/head.json"
  check allow "write own prefix" gcloud storage cp "$RUN/evidence/$probe" "gs://$BKT/$PFX/$probe"
  check allow "delete own prefix" gcloud storage rm "gs://$BKT/$PFX/$probe"
  check allow "list bucket (documented limit)" gcloud storage ls "gs://$BKT/"
  check deny "read beside the prefix" gcloud storage cat "$beside"
  check deny "overwrite beside the prefix" gcloud storage cp "$RUN/evidence/$probe" "$beside"
  check deny "delete beside the prefix" gcloud storage rm "$beside"
  check deny "write beside the prefix" gcloud storage cp "$RUN/evidence/$probe" "gs://$BKT/outside/$probe"
  check deny "read another context's state bucket" gcloud storage cat "$other"
  check deny "write another context's state bucket" gcloud storage cp "$RUN/evidence/$probe" "gs://$OTHER_BKT/nagare/tan-nb-exp/$probe"
  check deny "read the backup bucket" gcloud storage ls "gs://tan-nb-exp-$CTX-backups/"
  check deny "read the image bucket" gcloud storage ls "gs://tan-nb-exp-$CTX-images/"
  check deny "list project buckets" gcloud storage buckets list --project "$PROJECT"
  check deny "bucket IAM change" gcloud storage buckets add-iam-policy-binding "gs://$BKT" --member="serviceAccount:$(jq -r .client_email "$B/.config/gcloud/deployer-key.json")" --role=roles/storage.admin
  check deny "list instances" gcloud compute instances list --project "$PROJECT"
  check deny "list service accounts" gcloud iam service-accounts list --project "$PROJECT"
  check deny "create a key for itself" gcloud iam service-accounts keys create "$RUN/evidence/never.json" --iam-account "$(jq -r .client_email "$B/.config/gcloud/deployer-key.json")"
  check deny "project IAM policy" gcloud projects get-iam-policy "$PROJECT"
  check deny "list secrets" gcloud secrets list --project "$PROJECT"
  rm -f "$RUN/evidence/never.json"
  # Artifact Registry: push the smallest release image into each repository.
  src="$(jq -r '.releaseImages.images.cloudflared.storePath' $HOME/Keikaku/bokuno/nagare/release.json)"
  [ -d "$src" ] || die "no local OCI layout to push"
  tok="$(D gcloud auth print-access-token 2>/dev/null)" || die "the bundle key cannot get a token"
  pol="$RUN/evidence/skopeo-policy.json"; printf '{"default":[{"type":"insecureAcceptAnything"}]}' > "$pol"
  check allow "push to the delegation repository" skopeo copy --quiet --policy "$pol" --dest-registry-token "$tok" "oci:$src" "docker://$DEP_REPO/iam-probe:$label"
  check deny "push to the platform repository" skopeo copy --quiet --policy "$pol" --dest-registry-token "$tok" "oci:$src" "docker://$PLAT_REPO/iam-probe:$label"
  # The deployer's nagarectl through the same session: the store opens, history reads.
  check allow "nagarectl inventory history as the deployer" "$PKG/bin/nagarectl" --context "$CTX" inventory history --contract 1
fi
rm -f "$RUN/evidence/$probe"
log "$label: $pass passed, $fail failed (evidence $out)"
[ "$fail" = 0 ]
