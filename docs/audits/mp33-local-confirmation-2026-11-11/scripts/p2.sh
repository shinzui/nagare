. "$(dirname "$0")/lib.sh"
step "P2 EP-251 D7: the operator deploys a fixture app from the workstation"
out="$(OP app image-plan --archive "$R/hello-v1.tar" --destination "$IMG/op-hello:v1" --key op-hello-v1)"; printf '%s\n' "$out" | tail -4
setid OP_IMAGE_V1 "$(printf '%s\n' "$out" | imageid)"; ids
cd "$R/fixtures/op"
run OP app deploy -f nagare/Config.hs --tag v1 --image-resource "$OP_IMAGE_V1" 2>&1 | tail -4
K -n personal wait ksvc/op-hello --for=condition=Ready --timeout=300s
