#!/usr/bin/env bash
# E3: conditional writes. What each precondition failure returns, and whether it had an effect.
. ./lib.sh
res=${1:-configmap}
cm() { # rv uid value
  if [ $res = configmap ]; then
  jq -n --arg rv "$1" --arg uid "$2" --arg v "$3" '{apiVersion:"v1",kind:"ConfigMap",metadata:({name:"e3",namespace:"exp"} + (if $rv=="" then {} else {resourceVersion:$rv} end) + (if $uid=="" then {} else {uid:$uid} end)),data:{k:$v}}'
  else
  jq -n --arg rv "$1" --arg uid "$2" --arg v "$3" '{apiVersion:"serving.knative.dev/v1",kind:"Service",metadata:({name:"e3",namespace:"exp"} + (if $rv=="" then {} else {resourceVersion:$rv} end) + (if $uid=="" then {} else {uid:$uid} end)),spec:{template:{spec:{containers:[{image:"ghcr.io/knative/helloworld-go:latest",env:[{name:"TARGET",value:$v}]}]}}}}'
  fi; }
kres=$res; [ $res = ksvc ] && kres=services.serving.knative.dev
code() { grep -oE 'Response" verb="[A-Z]+" url="[^"]*" status="[0-9]+ [A-Za-z ]+"' | sed -E 's/.*verb="([A-Z]+)".*status="([^"]+)"/\1 \2/' | tr '\n' ';'; }
try() { # label, cmd...
  local l=$1; shift
  out=$("$@" -v=6 2>&1); rc=$?
  echo "$l | rc=$rc | http=$(echo "$out" | code) | msg=$(echo "$out" | grep -E '^(Error|error|The )' | head -1 | cut -c1-160)"
  echo "   after: $(kubectl get $kres e3 -n exp -o json 2>/dev/null | jq -c '{uid:.metadata.uid[0:8],rv:.metadata.resourceVersion,gen:.metadata.generation,v:(.data.k // .spec.template.spec.containers[0].env[0].value)}' || echo absent)"
}
apply() { cm "$@" | kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f - ; }
kubectl delete $kres e3 -n exp --ignore-not-found >/dev/null
cm "" "" v1 | kubectl create --field-manager=nagare-inventory -f - >/dev/null
sleep 2
uid=$(kubectl get $kres e3 -n exp -o jsonpath='{.metadata.uid}'); rv=$(kubectl get $kres e3 -n exp -o jsonpath='{.metadata.resourceVersion}')
echo "start uid=${uid:0:8} rv=$rv"
try "a create-existing" bash -c "$(declare -f cm); res=$res; cm '' '' v9 | kubectl create -f - -v=6"
try "b ssa current uid+rv (control)" bash -c "$(declare -f cm); res=$res; cm $rv $uid v2 | kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f - -v=6"
rv2=$(kubectl get $kres e3 -n exp -o jsonpath='{.metadata.resourceVersion}')
try "c ssa stale rv" bash -c "$(declare -f cm); res=$res; cm $rv $uid v3 | kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f - -v=6"
try "d ssa wrong uid, current rv" bash -c "$(declare -f cm); res=$res; cm $rv2 00000000-0000-0000-0000-000000000000 v4 | kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f - -v=6"
try "e put stale rv" bash -c "$(declare -f cm); res=$res; cm $rv $uid v5 | kubectl replace -f - -v=6"
try "f jsonpatch test rv fails" kubectl patch $kres e3 -n exp --type=json -p "[{\"op\":\"test\",\"path\":\"/metadata/resourceVersion\",\"value\":\"$rv\"},{\"op\":\"add\",\"path\":\"/metadata/annotations\",\"value\":{\"x\":\"y\"}}]"
try "g delete precond wrong uid" bash -c "kubectl delete --raw /$( [ $res = configmap ] && echo api/v1 || echo apis/serving.knative.dev/v1)/namespaces/exp/$( [ $res = configmap ] && echo configmaps || echo services)/e3 -f <(jq -n '{apiVersion:\"meta.k8s.io/v1\",kind:\"DeleteOptions\",preconditions:{uid:\"00000000-0000-0000-0000-000000000000\"}}') -v=6"
try "h delete precond stale rv" bash -c "kubectl delete --raw /$( [ $res = configmap ] && echo api/v1 || echo apis/serving.knative.dev/v1)/namespaces/exp/$( [ $res = configmap ] && echo configmaps || echo services)/e3 -f <(jq -n --arg u $uid --arg r $rv '{apiVersion:\"meta.k8s.io/v1\",kind:\"DeleteOptions\",preconditions:{uid:\$u,resourceVersion:\$r}}') -v=6"
rv3=$(kubectl get $kres e3 -n exp -o jsonpath='{.metadata.resourceVersion}')
kubectl delete $kres e3 -n exp >/dev/null; echo "-- deleted out of band"
try "i ssa uid+rv on absent" bash -c "$(declare -f cm); res=$res; cm $rv3 $uid v6 | kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f - -v=6"
kubectl delete $kres e3 -n exp --ignore-not-found >/dev/null
try "j ssa rv only on absent" bash -c "$(declare -f cm); res=$res; cm $rv3 '' v7 | kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f - -v=6"
kubectl delete $kres e3 -n exp --ignore-not-found >/dev/null
try "k ssa uid only on absent" bash -c "$(declare -f cm); res=$res; cm '' $uid v8 | kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f - -v=6"
try "l delete precond on absent" bash -c "kubectl delete --raw /$( [ $res = configmap ] && echo api/v1 || echo apis/serving.knative.dev/v1)/namespaces/exp/$( [ $res = configmap ] && echo configmaps || echo services)/e3x -f <(jq -n --arg u $uid '{apiVersion:\"meta.k8s.io/v1\",kind:\"DeleteOptions\",preconditions:{uid:\$u}}') -v=6"
