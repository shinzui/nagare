. "$(dirname "$0")/lib.sh"
step "P2 EP-248 D2/D3/D10: the operator applies a delegation; its scope carries the deployer's and builder's identities"
rm -rf "$R/reviews/delegation-ci"
run OP delegation create ci --namespace team-a --host-suffix -docs --kinds web-app --kinds worker --kinds static-site \
  --image-repository "$IMG/team-a" --team engineering --build-namespace team-a-build --save-plan "$R/reviews/delegation-ci" | tail -3
jq -r '.operations[] | (.operation // .) | .resource' "$R/reviews/delegation-ci/review.json" 2>/dev/null | sort | sed 's/^/  member /' || true
run OP inventory apply "$R/reviews/delegation-ci" --yes 2>&1 | tail -3
run K get serviceaccount -A -l nagare.dev/delegation=ci
run K get role,rolebinding -A -l nagare.dev/delegation=ci
run K get clusterrole,clusterrolebinding -l nagare.dev/delegation=ci
run K -n team-a get role nagare-deployer-ci -o jsonpath='{.rules}'; echo
run K -n nagare-system get role nagare-deployer-ci -o jsonpath='{.rules}'; echo
run K -n team-a-build get role nagare-builder-ci -o jsonpath='{.rules}'; echo
run K -n nagare-system get job nagare-deployer-ci-store-grant -o jsonpath='{.status.succeeded}'; echo
run K -n nagare-system logs job/nagare-deployer-ci-store-grant --tail=5
run K -n nagare-system get configmap nagare-deployer-ci-store -o jsonpath='{.data.policy\.json}'; echo
