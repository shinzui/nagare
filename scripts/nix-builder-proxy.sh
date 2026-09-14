#!/usr/bin/env bash
# Open an SSH byte stream to one explicitly identified GCE Nix builder.
# Intended for use as an OpenSSH ProxyCommand; stdin/stdout belong to SSH.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: nagare-nix-builder-proxy PROJECT ZONE INSTANCE" >&2
  exit 2
fi

PROJECT="$1"
ZONE="$2"
INSTANCE="$3"
SOCAT_BIN="$(command -v socat || true)"

if [ -z "$PROJECT" ] || [ -z "$ZONE" ] || [ -z "$INSTANCE" ]; then
  echo "nagare-nix-builder-proxy: project, zone, and instance must be non-empty" >&2
  exit 2
fi
if [ -z "$SOCAT_BIN" ]; then
  echo "nagare-nix-builder-proxy: socat not found on PATH" >&2
  exit 2
fi

status="$(gcloud --project="$PROJECT" compute instances describe "$INSTANCE" \
  --zone="$ZONE" --format='value(status)')"
if [ "$status" != "RUNNING" ]; then
  printf '[nagare-builder] starting %s in %s/%s\n' "$INSTANCE" "$PROJECT" "$ZONE" >&2
  gcloud --project="$PROJECT" compute instances start "$INSTANCE" \
    --zone="$ZONE" --quiet >/dev/null
fi

log_file="$(mktemp -t nagare-builder-tunnel.XXXXXX)"
tunnel_pid=""
cleanup() {
  if [ -n "$tunnel_pid" ]; then
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
  fi
  rm -f "$log_file"
}
trap cleanup EXIT HUP INT TERM

ready=0
for _attempt in 1 2 3 4 5; do
  local_port=$((30000 + RANDOM % 30000))
  : >"$log_file"
  gcloud --project="$PROJECT" compute start-iap-tunnel "$INSTANCE" 22 \
    --zone="$ZONE" --local-host-port="localhost:$local_port" --quiet \
    >"$log_file" 2>&1 &
  tunnel_pid=$!

  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if (echo >/dev/tcp/127.0.0.1/"$local_port") 2>/dev/null; then
      ready=1
      break
    fi
    if ! kill -0 "$tunnel_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if [ "$ready" -eq 1 ]; then
    break
  fi

  kill "$tunnel_pid" 2>/dev/null || true
  wait "$tunnel_pid" 2>/dev/null || true
  tunnel_pid=""
done

if [ "$ready" -ne 1 ]; then
  echo "nagare-nix-builder-proxy: IAP tunnel to $PROJECT/$ZONE/$INSTANCE did not become ready" >&2
  cat "$log_file" >&2 || true
  exit 1
fi

"$SOCAT_BIN" - "TCP:127.0.0.1:$local_port"
