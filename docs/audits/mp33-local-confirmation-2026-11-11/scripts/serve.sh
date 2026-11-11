# Sourced: HTTP checks through the ingress (local CA) and through the cluster-local gateway.
INGRESS_PORT=18443; INTERNAL_PORT=18446
start_forwards() {
  K -n cert-manager get secret nagare-local-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$R/ca.pem"
  K -n kourier-system port-forward svc/kourier "$INGRESS_PORT:443" >/dev/null 2>&1 & KOURIER_PF=$!
  K -n kourier-system port-forward svc/kourier-internal "$INTERNAL_PORT:80" >/dev/null 2>&1 & INTERNAL_PF=$!
  trap 'kill $KOURIER_PF $INTERNAL_PF 2>/dev/null || true' EXIT
  for _ in $(seq 1 30); do nc -z 127.0.0.1 "$INGRESS_PORT" 2>/dev/null && nc -z 127.0.0.1 "$INTERNAL_PORT" 2>/dev/null && break; sleep 1; done
}
public() { curl -sS -o "$R/body" -w '%{http_code}' --max-time 20 --cacert "$R/ca.pem" --connect-to "$1:443:127.0.0.1:$INGRESS_PORT" "https://$1${2:-/}" 2>/dev/null || true; }
origin() { curl -sS -o "$R/body" -w '%{http_code}' --max-time 20 -H "Host: $1" "http://127.0.0.1:$INTERNAL_PORT${2:-/}" 2>/dev/null || true; }
await() { # label wanted fn args...
  local label="$1" wanted="$2" got=""; shift 2
  for n in $(seq 1 300); do got="$("$@")"; [ "$got" = "$wanted" ] && { echo "ok   $label: $got after ${n}s"; return 0; }; sleep 1; done
  echo "UNEXPECTED: $label: got $got, wanted $wanted" >&2; exit 1
}
