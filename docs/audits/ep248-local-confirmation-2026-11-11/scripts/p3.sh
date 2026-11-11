. "$(dirname "$0")/lib.sh"
step "P3 EP-248 D4/D10: the operator issues the bundle"
rm -rf "$R/bundle"
OP delegation credentials ci --out "$R/bundle" --contract 1 > "$EV/credentials-1.json"; jq . "$EV/credentials-1.json"
( cd "$R/bundle" && find . -exec stat -c '%A %n' {} + | sort -k2 )
grep -E '^export NAGARE_(DEPLOYER|OPERATOR|INVENTORY_STORE)' "$R/bundle/.config/nagare/contexts/$CTX.env"
jq -r '.clusters[0].cluster.server, .users[0].name, .contexts[0].name' "$R/bundle/.config/nagare/kubeconfigs/$CTX.yaml"
jq -r 'keys | join(",")' "$R/bundle/.config/nagare/credentials/$CTX-s3.json"
run K -n nagare-system get secret -l nagare.dev/deployer-credential=nagare-deployer-ci -o name
run K -n team-a-build get secret -l nagare.dev/deployer-credential=nagare-builder-ci -o name
