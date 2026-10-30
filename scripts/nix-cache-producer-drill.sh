#!/usr/bin/env bash
# EP-230 M3: the producer path end to end against a disposable local Attic, with no cluster.
# Runs the pinned server image on SQLite and local storage behind the one loopback host the
# real server admits, creates nagare-cache as the reviewed cache transport does, mints a
# push-only token into a mode-0600 file, pushes a fresh input-addressed path through the real
# `nagarectl nix-cache push --endpoint`, and proves the narinfo is signed and that `nix copy`
# accepts the path under the cache's key and refuses it under another key of the same name.
# (A content-addressed path needs no signature, so the drill builds a derivation output.)
# The evidence stays under the drill root; the container and every token are removed on exit.
set -euo pipefail

: "${DOCKER_HOST:?the disposable Docker daemon socket, never the shared cp3 daemon}"
: "${NAGARE_DRILL_NAGARE:?the nix build .#nagare output, whose bin has nagarectl and attic}"
[ "$DOCKER_HOST" != "unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock" ] || { echo "refusing the shared cp3 daemon" >&2; exit 1; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for v in $(env | sed -n "s/^\(NAGARE_[A-Z_]*\|CLOUDSDK_[A-Z_]*\|PULUMI_[A-Z_]*\|KUBECONFIG\|XDG_CONFIG_HOME\)=.*/\1/p"); do
  case "$v" in NAGARE_DRILL_*) ;; *) unset "$v" ;; esac
done
umask 077
ROOT="${NAGARE_DRILL_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/nagare-attic-drill.XXXXXX")}"
CONTAINER=nagare-attic-drill
ENDPOINT=http://127.0.0.1:18080/
CACHE=nagare-cache
EV="$ROOT/evidence"
BIN="$NAGARE_DRILL_NAGARE/bin"
log() { printf '%s attic-drill: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "attic-drill: $*" >&2; exit 1; }
nix_() { nix --extra-experimental-features nix-command "$@"; }
get() { curl --max-time 5 -fsS -H 'Host: 127.0.0.1:18080' "$ENDPOINT$1"; }

[ -x "$BIN/nagarectl" ] && [ -x "$BIN/attic" ] || fail "$BIN must hold nagarectl and attic"
[ ! -e "$EV" ] || fail "$ROOT already holds a drill; remove it first"
! docker container inspect "$CONTAINER" >/dev/null 2>&1 || fail "container $CONTAINER exists; remove it first"
! curl --max-time 2 -s -o /dev/null "$ENDPOINT" || fail "127.0.0.1:18080 is in use"
mkdir -p "$EV" "$ROOT/server" "$ROOT/admin/attic"
chmod 700 "$ROOT"
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -f "$ROOT/admin.token" "$ROOT/push.token" "$ROOT/jwt.pem"
}
trap cleanup EXIT

# 1. The pinned server image, on SQLite and local storage (bind mounts from a macOS
# temporary directory arrive empty in a Colima VM, so the configuration is copied in).
archive="$(nix build "$REPO#attic-server-image" --no-link --print-out-paths)"
image="$(docker load -i "$archive" | sed -n 's/^Loaded image: //p' | tail -1)"
[ -n "$image" ] || fail "docker load named no image"
log "server image $image"
cat > "$ROOT/server/server.toml" <<'EOF'
listen = "[::]:8080"
allowed-hosts = ["127.0.0.1:18080"]
api-endpoint = "http://127.0.0.1:18080/"

[database]
url = "sqlite:///data/attic.db?mode=rwc"

[storage]
type = "local"
path = "/data/storage"

[chunking]
nar-size-threshold = 65536
min-size = 16384
avg-size = 65536
max-size = 262144

[compression]
type = "zstd"

[garbage-collection]
interval = "0 seconds"
EOF
# As cluster/bootstrap/nix-cache/create-secret.sh generates the token signing key.
if ! openssl genrsa -traditional -out "$ROOT/jwt.pem" 4096 >/dev/null 2>&1; then
  openssl genrsa -out "$ROOT/jwt.pem" 4096 >/dev/null 2>&1
fi
docker create --name "$CONTAINER" --platform linux/amd64 -p 127.0.0.1:18080:8080 \
  -e "ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=$(base64 < "$ROOT/jwt.pem" | tr -d '\n')" \
  --tmpfs /data "$image" -f /config/server.toml --mode monolithic >/dev/null
docker cp "$ROOT/server" "$CONTAINER:/config"
docker start "$CONTAINER" >/dev/null
for attempt in $(seq 1 60); do
  get "" 2>/dev/null | grep -q 'Attic Binary Cache' && break
  [ "$attempt" -lt 60 ] || { docker logs "$CONTAINER" >&2; fail "Attic never answered"; }
  sleep 1
done
log "Attic answers at $ENDPOINT"

# 2. The named cache, created and configured as scripts/inventory-cache-transport.sh does.
atticadm() { docker exec "$CONTAINER" atticadm -f /config/server.toml "$@"; }
atticadm make-token --sub nagare-bootstrap --validity 5m \
  --pull "$CACHE" --push "$CACHE" --create-cache "$CACHE" \
  --configure-cache "$CACHE" --configure-cache-retention "$CACHE" > "$ROOT/admin.token"
printf 'default-server = "drill"\n\n[servers.drill]\nendpoint = "%s"\ntoken-file = "%s"\n' "$ENDPOINT" "$ROOT/admin.token" > "$ROOT/admin/attic/config.toml"
XDG_CONFIG_HOME="$ROOT/admin" "$BIN/attic" cache create "drill:$CACHE" --public >/dev/null
XDG_CONFIG_HOME="$ROOT/admin" "$BIN/attic" cache configure "drill:$CACHE" --public --retention-period '30 days' >/dev/null
get "_api/v1/cache-config/$CACHE" > "$EV/cache-config.json"
KEY="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["public_key"])' "$EV/cache-config.json")"
log "created $CACHE, public key $KEY"

# 3. A push-only token in a mode-0600 file, as a producer would hold it.
atticadm make-token --sub operator-push --validity 15m --pull "$CACHE" --push "$CACHE" > "$ROOT/push.token"
[ "$(python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$ROOT/push.token")" = 0o600 ] || fail "push token is not mode 0600"

# 4. A fresh input-addressed path, pushed through the real command.
nonce="$(date -u +%Y%m%dT%H%M%SZ)-$$"
P="$(nix_ build --no-link --print-out-paths --impure --expr \
  "derivation { name = \"nagare-attic-drill\"; system = builtins.currentSystem; builder = \"/bin/sh\"; args = [ \"-c\" \"echo $nonce > \$out\" ]; }")"
log "pushing $P"
PATH="$BIN:$PATH" NAGARE_TRACE_FILE="$EV/push.trace.json" "$BIN/nagarectl" nix-cache push \
  --endpoint "$ENDPOINT" --token-file "$ROOT/push.token" "$P" --contract 1 > "$EV/push.json" 2> "$EV/push.err" \
  || { cat "$EV/push.err" >&2; fail "nagarectl nix-cache push failed"; }
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["document"]=="nix-cache-push-result" and d["outcome"]=="pushed" and d["paths"]==[sys.argv[2]] else 1)' "$EV/push.json" "$P" \
  || fail "unexpected push result: $(cat "$EV/push.json")"
if grep -qF "$(cat "$ROOT/push.token")" "$EV/push.json" "$EV/push.err" "$EV/push.trace.json"; then fail "the token appears in the push output"; fi

# 5. The narinfo is signed by the cache, and nix accepts the path only under its key.
get "$CACHE/$(basename "$P" | cut -d- -f1).narinfo" > "$EV/narinfo"
SIG="$(grep "^Sig: $CACHE:" "$EV/narinfo")" || fail "the narinfo carries no $CACHE signature"
nix_ copy --from "$ENDPOINT$CACHE" --to "$ROOT/store-right-key" "$P" \
  --option trusted-public-keys "$KEY" > "$EV/copy-right-key.log" 2>&1 \
  || { cat "$EV/copy-right-key.log" >&2; fail "nix copy refused the path under the cache's key"; }
WRONG="$(nix_ key generate-secret --key-name "$CACHE" | nix_ key convert-secret-to-public)"
if nix_ copy --from "$ENDPOINT$CACHE" --to "$ROOT/store-wrong-key" "$P" \
  --option trusted-public-keys "$WRONG" > "$EV/copy-wrong-key.log" 2>&1; then
  fail "nix copy accepted the path under a wrong key"
fi
grep -q 'lacks a signature by a trusted key' "$EV/copy-wrong-key.log" || { cat "$EV/copy-wrong-key.log" >&2; fail "the wrong-key copy failed for another reason"; }

{
  printf 'pushed: %s\n' "$P"
  printf 'narinfo: %s\n' "$SIG"
  printf 'copy under %s: accepted\n' "$KEY"
  printf 'copy under %s: refused (%s)\n' "$WRONG" "$(grep -o 'lacks a signature by a trusted key' "$EV/copy-wrong-key.log" | head -1)"
} | tee "$EV/summary.txt"
log "PASS; evidence in $EV"
