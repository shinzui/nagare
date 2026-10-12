# shellcheck shell=bash
# Route x86_64-linux builds to the active context's builder (NAGARE_BUILDER_*),
# never to the operator machine's default builders (F121).
#
# The macOS Nix daemon performs distributed builds as root and does not inherit
# the caller's ProxyCommand configuration. A pinned loopback IAP endpoint makes
# the context builder reachable by that daemon.
#
#   _nagare_builder_open PROJECT ZONE INSTANCE KEY
#     Starts the builder if needed, opens the tunnel, pins its host key, and sets
#     NAGARE_BUILDER_SPEC for `nix build --builders`. NIX_BUILDER_TUNNEL_PORT with
#     NIX_BUILDER_HOST_KEY_B64 selects an already-open tunnel instead.
#   _nagare_builder_close
#     Stops the tunnel the open call started.

_nagare_builder_close() {
  if [ -n "${NAGARE_BUILDER_TUNNEL_PID:-}" ]; then
    kill "${NAGARE_BUILDER_TUNNEL_PID}" 2>/dev/null || true
    wait "${NAGARE_BUILDER_TUNNEL_PID}" 2>/dev/null || true
  fi
  [ -z "${NAGARE_BUILDER_TUNNEL_LOG:-}" ] || rm -f "${NAGARE_BUILDER_TUNNEL_LOG}"
  NAGARE_BUILDER_TUNNEL_PID=""
  NAGARE_BUILDER_TUNNEL_LOG=""
}

_nagare_builder_open() {
  local project="$1" zone="$2" instance="$3" key="$4"
  local port host_key_b64 host_key_line scanned_host_key_b64 status ready deadline
  port="${NIX_BUILDER_TUNNEL_PORT:-}"
  host_key_b64="${NIX_BUILDER_HOST_KEY_B64:-}"
  NAGARE_BUILDER_SPEC=""
  NAGARE_BUILDER_TUNNEL_PID=""
  NAGARE_BUILDER_TUNNEL_LOG=""
  # The daemon drops a client-side --builders from an untrusted user and falls
  # back to the machine's default builders.
  nix store info --json 2>/dev/null | jq -e '.trusted == true or .trusted == 1' >/dev/null || {
    echo "refusing build: the Nix daemon does not trust this user, so it would ignore the context builder" >&2; return 2;
  }
  if [ -n "${port}" ]; then
    [[ "${port}" =~ ^[0-9]+$ ]] && [ "${port}" -gt 0 ] && [ "${port}" -le 65535 ] \
      && [[ "${host_key_b64}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || {
        echo "external builder tunnel requires a valid port and pinned host key" >&2; return 2;
      }
  else
    status="$(gcloud --project="${project}" compute instances describe "${instance}" \
      --zone="${zone}" --format='value(status)')" || return 1
    if [ "${status}" != RUNNING ]; then
      gcloud --project="${project}" compute instances start "${instance}" \
        --zone="${zone}" --quiet >/dev/null || return 1
    fi
    NAGARE_BUILDER_TUNNEL_LOG="$(mktemp -t nagare-builder-daemon-tunnel.XXXXXX)"
    ready=0
    for _attempt in 1 2 3 4 5; do
      port=$((30000 + RANDOM % 30000))
      : >"${NAGARE_BUILDER_TUNNEL_LOG}"
      gcloud --project="${project}" compute start-iap-tunnel "${instance}" 22 \
        --zone="${zone}" --local-host-port="localhost:${port}" --quiet \
        >"${NAGARE_BUILDER_TUNNEL_LOG}" 2>&1 &
      NAGARE_BUILDER_TUNNEL_PID=$!
      deadline=$((SECONDS + 60))
      while [ "${SECONDS}" -lt "${deadline}" ]; do
        if (echo ""; sleep 1) | nc -w 5 127.0.0.1 "${port}" 2>/dev/null | grep '^SSH-' >/dev/null; then
          ready=1
          break
        fi
        kill -0 "${NAGARE_BUILDER_TUNNEL_PID}" 2>/dev/null || break
        sleep 1
      done
      [ "${ready}" -eq 1 ] && break
      kill "${NAGARE_BUILDER_TUNNEL_PID}" 2>/dev/null || true
      wait "${NAGARE_BUILDER_TUNNEL_PID}" 2>/dev/null || true
      NAGARE_BUILDER_TUNNEL_PID=""
    done
    if [ "${ready}" -ne 1 ]; then
      cat "${NAGARE_BUILDER_TUNNEL_LOG}" >&2 || true
      _nagare_builder_close
      echo "builder IAP tunnel did not become ready" >&2
      return 1
    fi
    host_key_line="$(ssh-keyscan -T 5 -t ed25519 -p "${port}" 127.0.0.1 2>/dev/null \
      | awk '$2 == "ssh-ed25519" {print $2 " " $3; exit}')" || true
    if [ -z "${host_key_line}" ]; then
      _nagare_builder_close
      echo "builder host key could not be read through the IAP tunnel" >&2
      return 1
    fi
    scanned_host_key_b64="$(printf '%s\n' "${host_key_line}" | base64 | tr -d '\n')"
    if [ -n "${host_key_b64}" ] && [ "${host_key_b64}" != "${scanned_host_key_b64}" ]; then
      _nagare_builder_close
      echo "builder host key differs from the pinned key" >&2
      return 1
    fi
    host_key_b64="${scanned_host_key_b64}"
  fi
  NAGARE_BUILDER_SPEC="ssh-ng://builder@localhost:${port} x86_64-linux ${key} 4 1 big-parallel,benchmark,kvm - ${host_key_b64}"
}
