. "$(dirname "$0")/lib.sh"; ids
step "P4 the deployer's home (by hand; EP-248 issues it from a bundle) and its refusals"
mkdir -p "$CIHOME/config/nagare/contexts" "$CIHOME/config/nagare/kubeconfigs" "$CIHOME/state" "$CIHOME/cache"
chmod 700 "$CIHOME"
{ grep -v -E '^export NAGARE_(DEPLOYER|OPERATOR)=' "$XDG_CONFIG_HOME/nagare/contexts/mp33.env"; echo 'export NAGARE_DEPLOYER=ci'; } > "$CIHOME/config/nagare/contexts/mp33.env"
cp "$XDG_CONFIG_HOME/nagare/kubeconfigs/mp33.yaml" "$CIHOME/config/nagare/kubeconfigs/mp33.yaml"
# The fixture store credential: the object store's administrator key (EP-248 issues a scoped one).
( umask 077; K -n nagare-system get secret nagare-minio-credentials -o json \
  | jq '{accessKeyId: (.data.AWS_ACCESS_KEY_ID|@base64d), secretAccessKey: (.data.AWS_SECRET_ACCESS_KEY|@base64d)}' > "$CIHOME/store-credentials.json" )
grep -E 'NAGARE_(DEPLOYER|INVENTORY_STORE)' "$CIHOME/config/nagare/contexts/mp33.env"
run CI inventory status --scope application:op-hello
run CI inventory history --limit 2
refused CI delegation create rogue --namespace x --kinds web-app --image-repository "$IMG/x" --team t --save-plan "$R/reviews/never"
refused CI platform status
cd "$R/fixtures/app"
refused CI app check -f nagare/Config.hs
refused CI app deploy -f nagare/Config.hs --tag v1 --image-resource "$OP_IMAGE_V1" --dry-run
