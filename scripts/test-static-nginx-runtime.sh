#!/usr/bin/env bash
# EP-189: run a generated StaticSite server block in a real Nginx and assert the
# HTTP behaviour a reader sees: redirects are relative (they never expose the
# container's internal port), text is served as UTF-8, and binary assets are
# served byte for byte.
#
# Usage: test-static-nginx-runtime.sh [SERVER_BLOCK]
# SERVER_BLOCK defaults to the renderer's golden output. Only its `root` and
# `listen` lines are rewritten, so the bytes under test are the renderer's.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
server_block="${1:-$repo_root/cli/nagare-dsl/test/golden/static-site.nginx.conf}"
nginx_bin="$(command -v nginx)"
mime_types="$(dirname "$nginx_bin")/../conf/mime.types"
[ -f "$mime_types" ] || { echo "FAIL: no mime.types at $mime_types" >&2; exit 1; }

work="$(mktemp -d)"
nginx_pid=""
cleanup() {
  if [ -n "$nginx_pid" ]; then kill "$nginx_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

# Document root.
html="$work/html"
mkdir -p "$html/guide" "$html/assets" "$work/temp"
printf '<!doctype html><title>guide</title>\n' > "$html/guide/index.html"
printf '<!doctype html><title>new</title>\n' > "$html/new.html"
printf '<!doctype html><title>404</title>\n' > "$html/404.html"
printf 'Em dash \xe2\x80\x94 and caf\xc3\xa9.\n' > "$html/example.txt"
printf '/* caf\xc3\xa9 \xe2\x80\x94 styles */\nbody { margin: 0; }\n' > "$html/style.css"
printf 'console.log("caf\xc3\xa9 \xe2\x80\x94");\n' > "$html/app.js"
# A minimal 1x1 PNG, including a NUL and high bytes so a transcoding bug shows.
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xf8\xff\xff?\x00\x05\xfe\x02\xfe\xa7\x35\x81\x84\x00\x00\x00\x00IEND\xaeB`\x82' > "$html/assets/logo.png"

start_nginx() {
  local port="$1"
  sed -e "s|^    root .*;|    root $html;|" \
      -e "s|^    listen 8080;|    listen 127.0.0.1:$port;|" \
      "$server_block" > "$work/server.conf"
  cat > "$work/nginx.conf" <<EOF
pid $work/nginx.pid;
error_log stderr;
daemon off;
events {}
http {
    client_body_temp_path $work/temp/client;
    proxy_temp_path $work/temp/proxy;
    fastcgi_temp_path $work/temp/fastcgi;
    uwsgi_temp_path $work/temp/uwsgi;
    scgi_temp_path $work/temp/scgi;
    include $mime_types;
    default_type application/octet-stream;
    access_log off;
    include $work/server.conf;
}
EOF
  # Nginx writes its pid file only after binding, so the file means this Nginx
  # owns the port; an exit means it did not (for example, the port is busy).
  rm -f "$work/nginx.pid"
  "$nginx_bin" -e stderr -p "$work" -c "$work/nginx.conf" 2> "$work/nginx.log" &
  nginx_pid=$!
  for _ in $(seq 1 50); do
    if [ -s "$work/nginx.pid" ]; then return 0; fi
    if ! kill -0 "$nginx_pid" 2>/dev/null; then nginx_pid=""; return 1; fi
    sleep 0.1
  done
  kill "$nginx_pid" 2>/dev/null || true
  nginx_pid=""
  return 1
}

port=""
for candidate in $(seq 18189 18209); do
  if start_nginx "$candidate"; then port="$candidate"; break; fi
done
if [ -z "$port" ]; then
  echo "FAIL: nginx did not start on any port in 18189-18209" >&2
  cat "$work/nginx.log" >&2
  exit 1
fi

base="http://127.0.0.1:$port"
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# request PATH -> sets status, headers (CR stripped), body file
request() {
  curl -s -H 'Host: docs.example.test' -D "$work/headers" -o "$work/body" "$base$1"
  status="$(head -n1 "$work/headers" | tr -d '\r' | cut -d' ' -f2)"
}
header() {
  tr -d '\r' < "$work/headers" | sed -n "s/^$1: //Ip" | head -n1
}
expect_status() {
  [ "$status" = "$2" ] || fail "GET $1: status $status, want $2"
}
expect_header() {
  local got
  got="$(header "$2")"
  [ "$got" = "$3" ] || fail "GET $1: $2 '$got', want '$3'"
}
expect_body() {
  cmp -s "$work/body" "$2" || fail "GET $1: body differs from $2"
}

request /guide
expect_status /guide 301
expect_header /guide Location /guide/

request /guide/
expect_status /guide/ 200
expect_body /guide/ "$html/guide/index.html"

request /old
expect_status /old 301
expect_header /old Location /new

request /example.txt
expect_status /example.txt 200
expect_header /example.txt Content-Type 'text/plain; charset=utf-8'
expect_body /example.txt "$html/example.txt"

request /style.css
expect_status /style.css 200
expect_header /style.css Content-Type 'text/css; charset=utf-8'

request /app.js
expect_status /app.js 200
expect_header /app.js Content-Type 'application/javascript; charset=utf-8'

request /assets/logo.png
expect_status /assets/logo.png 200
expect_header /assets/logo.png Content-Type 'image/png'
want_sha="$(sha256sum < "$html/assets/logo.png" | cut -d' ' -f1)"
got_sha="$(sha256sum < "$work/body" | cut -d' ' -f1)"
[ "$got_sha" = "$want_sha" ] || fail "GET /assets/logo.png: sha256 $got_sha, want $want_sha"

if [ "$failures" -ne 0 ]; then
  echo "static-nginx-runtime: $failures assertion(s) failed" >&2
  exit 1
fi
echo "static-nginx-runtime: all assertions passed"
