. "$(dirname "$0")/lib.sh"
step "P3 EP-247 D1/D9: the operator applies a delegation"
rm -rf "$R/reviews/delegation-ci"
run OP delegation create ci --namespace team-a --host-suffix -docs --kinds web-app --kinds worker --kinds static-site \
  --image-repository "$IMG/team-a" --team engineering --build-namespace team-a-build --save-plan "$R/reviews/delegation-ci"
run OP inventory apply "$R/reviews/delegation-ci" --yes 2>&1 | tail -3
run K get ns -l nagare.dev/delegation=ci --show-labels
run K -n team-a get resourcequota,limitrange
run K -n nagare-system get configmap nagare-delegation-ci -o jsonpath='{.data}'; echo
run OP delegation show ci --contract 1
