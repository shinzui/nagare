. "$(dirname "$0")/lib.sh"
step "P7 EP-248 D7/D8/D10: revoking the delegation empties the deployer's Roles and removes its store user in one review"
rm -rf "$R/reviews/revoke-ci"
run OP delegation revoke ci --save-plan "$R/reviews/revoke-ci" | tail -3
run OP inventory apply "$R/reviews/revoke-ci" --yes 2>&1 | tail -3
run K -n team-a get role nagare-deployer-ci -o jsonpath='{.rules}'; echo
run K -n nagare-system logs job/nagare-deployer-ci-store-revoke --tail=3
refused DK -n team-a get ksvc
refused DK -n nagare-system get configmap nagare-access-backends
probe "$R/bundle2" 'mc ls b/nagare-inventory/ep248/ >/dev/null 2>&1 && echo "revoked key allowed" || echo "revoked key refused"' | tee "$EV/p7-key.txt"
grep -Eq 'revoked key refused|alias-refused' "$EV/p7-key.txt"
refused DN worker deploy --rendered /work/in/rendered/worker.json --tag v1 --image-resource "$(. "$R/ids.env"; echo "$HELLO_IMAGE")"
run K -n team-a get ksvc,deploy -o name
