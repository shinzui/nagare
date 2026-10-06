#!/usr/bin/env bash
# E7: deletion with Nagare's propagation policies; E8: Job failure and immutability; E11: quantity canonicalization.
. ./lib.sh
del() { # apipath uid rv policy
  jq -n --arg u "$2" --arg r "$3" --arg p "$4" '{apiVersion:"meta.k8s.io/v1",kind:"DeleteOptions",preconditions:{uid:$u,resourceVersion:$r},propagationPolicy:$p}' > /tmp/fp-del.json
  kubectl delete --raw "$1" -f /tmp/fp-del.json 2>&1 | jq -c '{kind, dt:.metadata.deletionTimestamp, fin:.metadata.finalizers, status:.status}' 2>/dev/null || true; }
echo "== E7a PVC in use by a pod, Orphan delete with uid+rv preconditions"
jq -n '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:"e7",namespace:"exp"},spec:{accessModes:["ReadWriteOnce"],resources:{requests:{storage:"10Mi"}}}}' | kubectl apply --server-side --field-manager=exp -f - >/dev/null
jq -n '{apiVersion:"v1",kind:"Pod",metadata:{name:"e7-user",namespace:"exp"},spec:{terminationGracePeriodSeconds:1,containers:[{name:"c",image:"registry.k8s.io/pause:3.10",volumeMounts:[{name:"d",mountPath:"/d"}]}],volumes:[{name:"d",persistentVolumeClaim:{claimName:"e7"}}]}}' | kubectl apply -f - >/dev/null
kubectl wait --for=condition=ready pod/e7-user -n exp --timeout=90s >/dev/null
read uid rv < <(kubectl get pvc e7 -n exp -o jsonpath='{.metadata.uid} {.metadata.resourceVersion}')
echo "DELETE response: $(del /api/v1/namespaces/exp/persistentvolumeclaims/e7 $uid $rv Orphan)"
w=$(kubectl wait --for=delete pvc/e7 -n exp --timeout=10s 2>&1); echo "wait --for=delete 10s: rc=$? ${w:0:80}"
kubectl get pvc e7 -n exp -o json | jq -c '{uid:.metadata.uid[0:8], rv:.metadata.resourceVersion, dt:.metadata.deletionTimestamp, fin:.metadata.finalizers, phase:.status.phase, stampedAnnotationsStillThere:true}'
echo "-- second DELETE with the original rv precondition:"; del /api/v1/namespaces/exp/persistentvolumeclaims/e7 $uid $rv Orphan; kubectl delete --raw /api/v1/namespaces/exp/persistentvolumeclaims/e7 -f /tmp/fp-del.json 2>&1 | head -1 | cut -c1-160
kubectl delete pod e7-user -n exp --wait=true >/dev/null; kubectl wait --for=delete pvc/e7 -n exp --timeout=30s >/dev/null && echo "pvc gone after pod deleted"
echo "== E7b Knative Service, Orphan delete (Nagare's policy for serving.knative.dev/service)"
jq -n '{apiVersion:"serving.knative.dev/v1",kind:"Service",metadata:{name:"e7k",namespace:"exp"},spec:{template:{spec:{containers:[{image:"ghcr.io/knative/helloworld-go:latest"}]}}}}' | kubectl apply --server-side --field-manager=exp -f - 2>/dev/null >/dev/null
kubectl wait --for=condition=ready services.serving.knative.dev/e7k -n exp --timeout=120s >/dev/null
read uid rv < <(kubectl get services.serving.knative.dev e7k -n exp -o jsonpath='{.metadata.uid} {.metadata.resourceVersion}')
echo "DELETE response: $(del /apis/serving.knative.dev/v1/namespaces/exp/services/e7k $uid $rv Orphan)"
kubectl wait --for=delete services.serving.knative.dev/e7k -n exp --timeout=30s >/dev/null && echo "ksvc gone"
sleep 3; echo "left behind: $(kubectl get configurations.serving.knative.dev,routes.serving.knative.dev,revisions.serving.knative.dev,ingresses.networking.internal.knative.dev -n exp -o name 2>/dev/null | grep e7k | tr '\n' ' ')"
echo "== E8 Job failure; template immutability"
jq -n '{apiVersion:"batch/v1",kind:"Job",metadata:{name:"e8",namespace:"exp"},spec:{backoffLimit:0,template:{spec:{restartPolicy:"Never",containers:[{name:"c",image:"busybox:1.36",command:["sh","-c","exit 3"]}]}}}}' | kubectl apply --server-side --field-manager=exp -f - >/dev/null
for i in $(seq 1 60); do c=$(kubectl get job e8 -n exp -o json | jq -c '[.status.conditions[]?|"\(.type)=\(.status)(\(.reason))"]'); echo "$c" | grep -q 'Failed=True' && break; sleep 1; done; echo "job conditions: $c"
jq -n '{apiVersion:"batch/v1",kind:"Job",metadata:{name:"e8",namespace:"exp"},spec:{backoffLimit:0,template:{spec:{restartPolicy:"Never",containers:[{name:"c",image:"busybox:1.36",command:["sh","-c","exit 0"]}]}}}}' | kubectl apply --server-side --field-manager=exp -f - 2>&1 | head -1 | cut -c1-170
echo "== E11 quantity canonicalization in a Deployment"
jq -n '{apiVersion:"apps/v1",kind:"Deployment",metadata:{name:"e11",namespace:"exp"},spec:{replicas:0,selector:{matchLabels:{app:"e11"}},template:{metadata:{labels:{app:"e11"}},spec:{containers:[{name:"c",image:"registry.k8s.io/pause:3.10",resources:{requests:{cpu:"1000m",memory:"1024Mi"},limits:{memory:"0.5Gi","ephemeral-storage":"1000M"}}}]}}}}' | kubectl apply --server-side --field-manager=exp -f - >/dev/null
kubectl get deploy e11 -n exp -o json | jq -c '.spec.template.spec.containers[0].resources'
