. "$(dirname "$0")/lib.sh"
step "P6 EP-248 D10: the store key reaches only the inventory prefix"
CHECKS='for t in "ls b/nagare-inventory/ep248/" "ls b/nagare-inventory/" "ls b/nagare-backups/" "cat b/nagare-inventory/ep248/head.json" "pipe b/nagare-inventory/other/probe" "pipe b/nagare-inventory/ep248/probe-ep248" "rm b/nagare-inventory/ep248/probe-ep248"; do if echo probe | mc $t >/dev/null 2>&1; then echo "allowed: mc $t"; else echo "refused: mc $t"; fi; done'
probe "$R/bundle" "$CHECKS" | tee "$EV/p6-store-first.txt"
grep -q '^allowed: mc ls b/nagare-inventory/ep248/$' "$EV/p6-store-first.txt"
grep -q '^allowed: mc cat b/nagare-inventory/ep248/head.json$' "$EV/p6-store-first.txt"
grep -q '^refused: mc ls b/nagare-inventory/$' "$EV/p6-store-first.txt"
grep -q '^refused: mc ls b/nagare-backups/$' "$EV/p6-store-first.txt"
grep -q '^refused: mc pipe b/nagare-inventory/other/probe$' "$EV/p6-store-first.txt"

step "P6b EP-248 D7: running credentials again rotates; the old token and key stop working"
rm -rf "$R/bundle2"
OP delegation credentials ci --out "$R/bundle2" --contract 1 > "$EV/credentials-2.json"; jq "{tokenExpiresAt, storeKeyId, retired}" "$EV/credentials-2.json"
D /bin/bash -c 'mkdir -p /work/home2' && tar -C "$R/bundle2" -cf - . | D tar -x -C /work/home2
refused DK -n team-a get ksvc
D kubectl --kubeconfig /work/home2/.config/nagare/kubeconfigs/$CTX.yaml --context "$CTX" -n team-a get ksvc
probe "$R/bundle" 'mc ls b/nagare-inventory/ep248/ >/dev/null 2>&1 && echo "old key allowed" || echo "old key refused"' | tee "$EV/p6-old-key.txt"
grep -Eq 'old key refused|alias-refused' "$EV/p6-old-key.txt"
probe "$R/bundle2" 'mc ls b/nagare-inventory/ep248/ >/dev/null 2>&1 && echo "new key allowed" || echo "new key refused"' | tee "$EV/p6-new-key.txt"
grep -q 'new key allowed' "$EV/p6-new-key.txt"
# The Pod moves to the new bundle.
D /bin/bash -c 'rm -rf /work/home && mv /work/home2 /work/home'
run DN inventory history --limit 2
