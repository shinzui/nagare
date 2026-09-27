#!/usr/bin/env bash
# Prove that a fenced engine remains reachable over its local socket while
# another Pod loses network ingress to it. This is a disposable CNI probe,
# not maintenance-session acceptance.
set -euo pipefail

context="${1:?pass a disposable Kubernetes context}"
namespace="nagare-ep161-network-$$"
kube() { kubectl --context "$context" "$@"; }

cleanup() {
  kube delete namespace "$namespace" --ignore-not-found --wait=true --timeout=120s \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT

kube create namespace "$namespace" >/dev/null
kube -n "$namespace" run server --image=postgres:18 \
  --env=POSTGRES_PASSWORD=probe-only --restart=Never --labels=app=server >/dev/null
kube -n "$namespace" run client --image=postgres:18 \
  --restart=Never --command -- sleep 3600 >/dev/null
kube -n "$namespace" wait --for=condition=Ready pod/server pod/client --timeout=120s >/dev/null

server_ip="$(kube -n "$namespace" get pod server -o jsonpath='{.status.podIP}')"
case "$server_ip" in
  *[!0-9.]*|'') printf 'server Pod has no IPv4 address\n' >&2; exit 1 ;;
esac
remote_ready=0
for _ in {1..20}; do
  if kube -n "$namespace" exec client -- pg_isready -t 2 -h "$server_ip" -p 5432 \
      >/dev/null 2>&1; then
    remote_ready=1
    break
  fi
  sleep 1
done
if [[ "$remote_ready" != 1 ]]; then
  printf 'remote database client did not become ready before ingress denial\n' >&2
  exit 1
fi

kube create -f - >/dev/null <<EOF
{
  "apiVersion": "networking.k8s.io/v1",
  "kind": "NetworkPolicy",
  "metadata": {"name": "deny-server-ingress", "namespace": "$namespace"},
  "spec": {
    "podSelector": {"matchLabels": {"app": "server"}},
    "policyTypes": ["Ingress"],
    "ingress": []
  }
}
EOF

denied=0
for _ in {1..20}; do
  if kube -n "$namespace" exec client -- pg_isready -t 2 -h "$server_ip" -p 5432 \
      >/dev/null 2>&1; then
    sleep 1
  else
    denied=1
    break
  fi
done
if [[ "$denied" != 1 ]]; then
  printf 'network ingress remained reachable after the deny policy\n' >&2
  exit 1
fi
database_ready=0
for _ in {1..20}; do
  if kube -n "$namespace" exec server -- psql -U postgres -d postgres \
      -Atqc 'select 1' >/dev/null 2>&1; then
    database_ready=1
    break
  fi
  sleep 1
done
if [[ "$database_ready" != 1 ]]; then
  printf 'local database client did not become ready\n' >&2
  exit 1
fi

# Recovery must be able to find a session that outlived its invoking client.
# Start a detached, marked local client, then terminate only that backend.
client_count_sql="select count(*) from pg_stat_activity where backend_type = 'client backend' and pid <> pg_backend_pid()"
client_count() {
  kube -n "$namespace" exec server -- psql -U postgres -d postgres \
    -Atqc "$client_count_sql" 2>/dev/null
}
if [[ "$(client_count)" != 0 ]]; then
  printf 'unexpected PostgreSQL client before marked session\n' >&2
  exit 1
fi
kube -n "$namespace" exec server -- sh -c \
  'PGAPPNAME=nagare-maintenance-probe psql -U postgres -d postgres -c "select pg_sleep(120)" >/tmp/nagare-maintenance-probe.log 2>&1 </dev/null &'
activity_sql="select pid from pg_stat_activity where application_name = 'nagare-maintenance-probe'"
marked_pid=""
for _ in {1..20}; do
  if observed="$(kube -n "$namespace" exec server -- psql -U postgres -d postgres \
      -Atqc "$activity_sql" 2>/dev/null)"; then
    marked_pid="${observed//$'\r'/}"
    if [[ "$marked_pid" =~ ^[0-9]+$ ]]; then
      break
    fi
  fi
  sleep 1
done
if [[ ! "$marked_pid" =~ ^[0-9]+$ ]]; then
  printf 'detached marked database session was not observed\n' >&2
  exit 1
fi
if [[ "$(client_count)" != 1 ]]; then
  printf 'server-side exclusion did not find the established client\n' >&2
  exit 1
fi
terminated="$(kube -n "$namespace" exec server -- psql -U postgres -d postgres \
  -Atqc "select pg_terminate_backend($marked_pid)" 2>/dev/null)"
terminated="${terminated//$'\r'/}"
if [[ "$terminated" != t ]]; then
  printf 'marked database session could not be terminated\n' >&2
  exit 1
fi
for _ in {1..20}; do
  if observed="$(kube -n "$namespace" exec server -- psql -U postgres -d postgres \
      -Atqc "$activity_sql" 2>/dev/null)"; then
    marked_pid="${observed//$'\r'/}"
    if [[ -z "$marked_pid" ]]; then
      break
    fi
  fi
  sleep 1
done
if [[ -n "$marked_pid" ]]; then
  printf 'marked database session survived recovery termination\n' >&2
  exit 1
fi
if [[ "$(client_count)" != 0 ]]; then
  printf 'server-side exclusion still finds a client after termination\n' >&2
  exit 1
fi
printf 'maintenance network probe passed: remote ingress denied, local socket and marked-session recovery usable\n'
