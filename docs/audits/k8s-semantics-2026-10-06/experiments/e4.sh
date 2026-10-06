#!/usr/bin/env bash
# E4: Knative Service readiness vs observedGeneration after a spec update.
. ./lib.sh
K=services.serving.knative.dev
kv() { jq -n --arg v "$1" --arg img "${2:-ghcr.io/knative/helloworld-go:latest}" '{apiVersion:"serving.knative.dev/v1",kind:"Service",metadata:{name:"e1",namespace:"exp"},spec:{template:{spec:{containers:[{image:$img,env:[{name:"TARGET",value:$v}]}]}}}}' | kubectl apply --server-side --field-manager=exp -f - 2>&1 | grep -v Warning; }
snap $K e1 before
echo "-- idle churn: rv over 60s"; for i in 1 2 3 4 5 6; do sleep 10; kubectl get $K e1 -n exp -o jsonpath='{.metadata.resourceVersion} '; done; echo
kubectl -n knative-serving scale deploy/controller --replicas=0 >/dev/null; kubectl -n knative-serving rollout status deploy/controller --timeout=60s >/dev/null; sleep 3
kv v3; snap $K e1 "spec-update, controller frozen"
out=$(kubectl wait --for=condition=ready $K/e1 -n exp --timeout=5s 2>&1); echo "kubectl wait --for=condition=ready (frozen): rc=$? $out"
kubectl get $K e1 -n exp -o json | jq -c '{nagare_knativeReady: ([.status.conditions[]|select(.type=="Ready" and .status=="True")]|length>0), gen:.metadata.generation, og:.status.observedGeneration, latestReady:.status.latestReadyRevisionName, traffic:[.status.traffic[]?|{revisionName,percent}]}'
kubectl -n knative-serving scale deploy/controller --replicas=1 >/dev/null
echo "-- controller resumed; sampling"
prev=""; for i in $(seq 1 120); do s=$(kubectl get $K e1 -n exp -o json | jq -c '{gen:.metadata.generation,og:.status.observedGeneration,ready:([.status.conditions[]|select(.type=="Ready")|.status+"/"+(.reason//"")]|first),latestReady:.status.latestReadyRevisionName,latestCreated:.status.latestCreatedRevisionName}'); [ "$s" != "$prev" ] && echo "t=$((i/2))s $s"; prev=$s; echo "$s" | grep -q '"ready":"True/"' && echo "$s" | grep -q '"og":3' && break; sleep 0.5; done
echo "-- bad image update"
kv v4 ghcr.io/knative/does-not-exist:nope
prev=""; for i in $(seq 1 180); do s=$(kubectl get $K e1 -n exp -o json | jq -c '{gen:.metadata.generation,og:.status.observedGeneration,ready:([.status.conditions[]|select(.type=="Ready")|.status+"/"+(.reason//"")]|first),cfg:([.status.conditions[]|select(.type=="ConfigurationsReady")|.status+"/"+(.reason//"")]|first),latestReady:.status.latestReadyRevisionName,latestCreated:.status.latestCreatedRevisionName,traffic:[.status.traffic[]?|.revisionName]}'); [ "$s" != "$prev" ] && echo "t=$((i/2))s $s"; prev=$s; echo "$s" | grep -q '"ready":"False' && break; sleep 0.5; done
out=$(kubectl wait --for=condition=ready $K/e1 -n exp --timeout=5s 2>&1); echo "kubectl wait (bad image): rc=$? ${out:0:120}"
