#!/usr/bin/env bash
# EP-250 D1 helper: a port-forward to the throwaway context's En and an authenticated call.
set -euo pipefail
R=$HOME/.local/state/nagare/drills/ep248
export KUBECONFIG=$R/config/nagare/kubeconfigs/ep248.yaml
K() { kubectl --context ep248 "$@"; }
KEY="$(K -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d)"
if ! curl -fsS -o /dev/null "http://127.0.0.1:18080/v1/openapi.json" -H "Authorization: Bearer $KEY" 2>/dev/null; then
  K -n nagare-system port-forward svc/en 18080:80 >/dev/null 2>&1 &
  echo $! > "$R/en-forward.pid"
  for _ in $(seq 1 30); do curl -fsS -o /dev/null "http://127.0.0.1:18080/v1/openapi.json" -H "Authorization: Bearer $KEY" 2>/dev/null && break; sleep 1; done
fi
en() { # METHOD PATH [BODY]
  curl -sS -w '\n%{http_code} %{time_total}\n' -X "$1" "http://127.0.0.1:18080$2" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' ${3:+--data "$3"}
}
