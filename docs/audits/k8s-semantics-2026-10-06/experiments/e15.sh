#!/usr/bin/env bash
# E15: how the API server stores resource quantities (RES-4 U7), for values
# whose canonical form is not obvious from the type's documentation. Each
# value goes through a ResourceQuota's spec.hard (requests.memory and
# requests.cpu, which carry no request <= limit validation) and, where a
# storage size makes sense, a PVC's spec.resources.requests.storage. Prints
# one JSON line per value: what was sent, what the server stored, and the
# warning kubectl printed for a PVC (a fractional byte count is accepted with a
# warning, not refused).
set -uo pipefail
: "${KUBECONFIG:?point at a disposable k3s v1.34.6 cluster}"
kubectl create namespace quantity >/dev/null 2>&1 || true
i=0
warnings=$(mktemp)
trap 'rm -f "$warnings"' EXIT
for value in 1.5Gi 0.5Gi 1536Mi 1.1Ki 0.1m 1e3 1500e0 2000m 1500m 1024 512Ki 1000Ki 1024Mi 2048Mi 1000M 1000m 1.5 0.5 100u 1e-3 1Ei; do
  i=$((i + 1))
  rq=$(jq -cn --arg n "q$i" --arg v "$value" '{apiVersion:"v1",kind:"ResourceQuota",metadata:{name:$n,namespace:"quantity"},spec:{hard:{"requests.memory":$v,"requests.cpu":$v}}}')
  rq_out=$(kubectl apply --server-side --field-manager=e15 -f <(echo "$rq") -o json 2>/dev/null)
  pvc=$(jq -cn --arg n "p$i" --arg v "$value" '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$n,namespace:"quantity"},spec:{accessModes:["ReadWriteOnce"],resources:{requests:{storage:$v}}}}')
  pvc_out=$(kubectl apply --server-side --field-manager=e15 -f <(echo "$pvc") -o json 2>"$warnings")
  warning=$(head -1 "$warnings")
  jq -cn --arg v "$value" --arg rq "$rq_out" --arg pvc "$pvc_out" --arg w "$warning" '
    def stored(s; path): (s | try (fromjson | getpath(path)) catch ("refused: " + (s | split("\n")[0])));
    {sent: $v,
     memory: stored($rq; ["spec","hard","requests.memory"]),
     cpu: stored($rq; ["spec","hard","requests.cpu"]),
     storage: stored($pvc; ["spec","resources","requests","storage"]),
     storageWarning: (if $w == "" then null else $w end)}'
done
kubectl delete namespace quantity --wait=false >/dev/null
