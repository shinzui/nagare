#!/usr/bin/env bash
. ./lib.sh
echo "== E9 DomainMapping to a Ready ksvc"
jq -n '{apiVersion:"serving.knative.dev/v1beta1",kind:"DomainMapping",metadata:{name:"e9.127-0-0-1.sslip.io",namespace:"exp"},spec:{ref:{name:"e11k",kind:"Service",apiVersion:"serving.knative.dev/v1"}}}' | kubectl apply --server-side --field-manager=exp -f - >/dev/null
prev=""; for i in $(seq 1 40); do s=$(kubectl get domainmappings.serving.knative.dev e9.127-0-0-1.sslip.io -n exp -o json | jq -c '{gen:.metadata.generation,og:.status.observedGeneration,conds:[.status.conditions[]?|"\(.type)=\(.status)(\(.reason//""))"]}'); [ "$s" != "$prev" ] && echo "t=$((i/2))s $s"; prev=$s; sleep 0.5; done
kubectl get clusterdomainclaims.networking.internal.knative.dev -o name 2>&1 | head -2
echo "== E12 lingering after DELETE: ConfigMap Orphan, StatefulSet Background, Namespace"
jq -n '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:"e12",namespace:"exp"},data:{a:"b"}}' | kubectl apply -f - >/dev/null
read uid rv < <(kubectl get cm e12 -n exp -o jsonpath='{.metadata.uid} {.metadata.resourceVersion}')
jq -n --arg u $uid --arg r $rv '{apiVersion:"meta.k8s.io/v1",kind:"DeleteOptions",preconditions:{uid:$u,resourceVersion:$r},propagationPolicy:"Orphan"}' > /tmp/fp-del.json
t0=$(date +%s%N); kubectl delete --raw /api/v1/namespaces/exp/configmaps/e12 -f /tmp/fp-del.json | jq -c '{dt:.metadata.deletionTimestamp,fin:.metadata.finalizers}'
kubectl wait --for=delete cm/e12 -n exp --timeout=30s >/dev/null; echo "configmap gone after $(( ($(date +%s%N)-t0)/1000000 )) ms"
read uid rv < <(kubectl get sts e6a -n exp -o jsonpath='{.metadata.uid} {.metadata.resourceVersion}')
jq -n --arg u $uid --arg r $rv '{apiVersion:"meta.k8s.io/v1",kind:"DeleteOptions",preconditions:{uid:$u,resourceVersion:$r},propagationPolicy:"Background"}' > /tmp/fp-del.json
t0=$(date +%s%N); kubectl delete --raw /apis/apps/v1/namespaces/exp/statefulsets/e6a -f /tmp/fp-del.json | jq -c '{dt:.metadata.deletionTimestamp,fin:.metadata.finalizers}'
kubectl wait --for=delete sts/e6a -n exp --timeout=30s >/dev/null; echo "sts gone after $(( ($(date +%s%N)-t0)/1000000 )) ms; pods left: $(kubectl get pods -n exp -l app=e6a --no-headers 2>/dev/null | wc -l)"
kubectl create ns exp-e12 >/dev/null; kubectl create cm x -n exp-e12 >/dev/null; kubectl delete ns exp-e12 --wait=false >/dev/null; kubectl get ns exp-e12 -o json | jq -c '{phase:.status.phase,dt:.metadata.deletionTimestamp,fin:.spec.finalizers}'; kubectl wait --for=delete ns/exp-e12 --timeout=60s >/dev/null && echo "namespace gone"
