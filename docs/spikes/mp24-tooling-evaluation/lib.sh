# Helpers shared by the EP-163 prototype drivers. Source after env.sh.

# The fixture's file manifest: sorted "sha256  path" lines for every file under
# /files in the writer pod (or under DIR in a named pod).
files_manifest() {
  local pod="${1:-deploy/writer}" dir="${2:-/files}"
  k -n app exec "$pod" -- sh -c "cd '$dir' && find . -type f ! -name lost+found -exec sha256sum {} + | sort -k2"
}

# Row count and an order-independent checksum of appdb.items.
pg_fingerprint() {
  local ns="${1:-app}" pod="${2:-pg-0}" db="${3:-appdb}"
  k -n "$ns" exec "$pod" -- sh -c \
    "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -h 127.0.0.1 -U postgres -d $db -tAc \"select count(*), md5(string_agg(id::text || ':' || body, ',' order by id)) from items\""
}

# Wait for a K8up object to reach a terminal condition; print its status.
k8up_wait() {
  local kind="$1" name="$2" timeout="${3:-300}" i=0
  while [ "$i" -lt "$timeout" ]; do
    local done
    done=$(k -n app get "$kind" "$name" -o jsonpath='{.status.finished}' 2>/dev/null || true)
    [ "$done" = "true" ] && break
    sleep 2; i=$((i + 2))
  done
  k -n app get "$kind" "$name" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
}

# Sample `kubectl top` for pods matching a namespace every 2 s for N seconds.
top_sample() {
  local ns="$1" secs="$2" i=0
  while [ "$i" -lt "$secs" ]; do
    k top pod -n "$ns" --no-headers 2>/dev/null | sed "s/^/$(date -u +%T) /"
    sleep 2; i=$((i + 2))
  done
}
