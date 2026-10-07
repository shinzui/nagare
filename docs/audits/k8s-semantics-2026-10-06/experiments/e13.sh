#!/usr/bin/env bash
# E13: server-side apply field ownership with Nagare's managers: create (Update) then apply without force.
set -u
NS=default
cm() { jq -n --arg v "$1" --arg d "$2" --arg uid "${3:-}" --arg rv "${4:-}" '{apiVersion:"v1",kind:"ConfigMap",metadata:({name:"e13",namespace:"default",annotations:{"nagare.dev/spec-digest":$d}} + (if $uid=="" then {} else {uid:$uid} end) + (if $rv=="" then {} else {resourceVersion:$rv} end)),data:{k:$v}}'; }
state() { kubectl get cm e13 -o json --show-managed-fields | jq -c '{rv:.metadata.resourceVersion,k:.data.k,k2:.data.k2,stamp:.metadata.annotations["nagare.dev/spec-digest"],managers:[.metadata.managedFields[]|"\(.manager)/\(.operation)"]}'; }
try() { local l=$1; shift; out=$("$@" 2>&1); echo "$l | rc=$? | $(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-230)"; echo "   $(state)"; }
kubectl delete cm e13 --ignore-not-found >/dev/null
cm v1 d1 | kubectl create --field-manager=nagare-inventory -f - >/dev/null
echo "created: $(state)"
uid=$(kubectl get cm e13 -o jsonpath='{.metadata.uid}')
try "a no-force apply over own create (Update) entry, uid only" bash -c "$(declare -f cm); cm v2 d2 $uid | kubectl apply --server-side --field-manager=nagare-inventory -f -"
try "b forced apply, uid only" bash -c "$(declare -f cm); cm v2 d2 $uid | kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f -"
try "c no-force apply after Nagare owns by Apply" bash -c "$(declare -f cm); cm v3 d3 $uid | kubectl apply --server-side --field-manager=nagare-inventory -f -"
kubectl patch cm e13 --type=merge --field-manager=kubectl-edit -p '{"data":{"k":"edited"}}' >/dev/null
echo "-- kubectl-edit changed data.k (a Nagare-managed field)"
try "d no-force apply after a foreign edit of a managed field" bash -c "$(declare -f cm); cm v4 d4 $uid | kubectl apply --server-side --field-manager=nagare-inventory -f -"
kubectl patch cm e13 --type=merge --field-manager=kubectl-edit -p '{"data":{"k":"v3"}}' >/dev/null
echo "-- kubectl-edit set data.k back to Nagare's value v3"
try "e no-force apply after a foreign write restoring an earlier value" bash -c "$(declare -f cm); cm v5 d5 $uid | kubectl apply --server-side --field-manager=nagare-inventory -f -"
kubectl delete cm e13 >/dev/null; cm v1 d1 | kubectl create --field-manager=nagare-inventory -f - >/dev/null; uid=$(kubectl get cm e13 -o jsonpath='{.metadata.uid}')
kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f <(cm v1 d1 $uid) >/dev/null
kubectl patch cm e13 --type=merge --field-manager=kubectl-edit -p '{"data":{"k2":"theirs"}}' >/dev/null
echo "-- fresh object, Nagare owns by Apply; kubectl-edit added unrelated data.k2: $(state)"
try "f no-force apply, other manager owns an unrelated field" bash -c "$(declare -f cm); cm v6 d6 $uid | kubectl apply --server-side --field-manager=nagare-inventory -f -"
echo "== Deployment: create, controller status writes, then no-force apply with uid only"
kubectl delete deploy e13 --ignore-not-found >/dev/null
dep() { jq -n --arg img "$1" --arg d "$2" --arg uid "${3:-}" '{apiVersion:"apps/v1",kind:"Deployment",metadata:({name:"e13",namespace:"default",annotations:{"nagare.dev/spec-digest":$d}} + (if $uid=="" then {} else {uid:$uid} end)),spec:{replicas:1,selector:{matchLabels:{app:"e13"}},template:{metadata:{labels:{app:"e13"}},spec:{containers:[{name:"c",image:$img}]}}}}'; }
dep registry.k8s.io/pause:3.10 d1 | kubectl create --field-manager=nagare-inventory -f - >/dev/null
kubectl rollout status deploy/e13 --timeout=90s >/dev/null
duid=$(kubectl get deploy e13 -o jsonpath='{.metadata.uid}')
kubectl get deploy e13 -o json --show-managed-fields | jq -c '[.metadata.managedFields[]|"\(.manager)/\(.operation)/\(.subresource // "-")"]'
out=$(dep registry.k8s.io/pause:3.9 d2 $duid | kubectl apply --server-side --field-manager=nagare-inventory -f - 2>&1); echo "g no-force: rc=$? ${out:0:230}"
out=$(dep registry.k8s.io/pause:3.9 d2 $duid | kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f - 2>&1); echo "h forced:   rc=$? ${out:0:120}"
kubectl rollout status deploy/e13 --timeout=90s >/dev/null
out=$(dep registry.k8s.io/pause:3.10 d3 $duid | kubectl apply --server-side --field-manager=nagare-inventory -f - 2>&1); echo "i no-force after Apply ownership, after a rollout (k3s wrote revision annotation): rc=$? ${out:0:160}"
kubectl get deploy e13 -o json --show-managed-fields | jq -c '[.metadata.managedFields[]|"\(.manager)/\(.operation)/\(.subresource // "-")"]'
echo "== E13b apply with resourceVersion \"0\" as create-if-absent"
kubectl delete cm e13b --ignore-not-found >/dev/null
mk() { jq -n --arg v "$1" '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:"e13b",namespace:"default",resourceVersion:"0"},data:{k:$v}}'; }
out=$(mk v1 | kubectl apply --server-side --field-manager=nagare-inventory -f - 2>&1); echo "absent, rv \"0\": rc=$? ${out:0:200}"
kubectl get cm e13b -o json --show-managed-fields 2>/dev/null | jq -c '{rv:.metadata.resourceVersion,k:.data.k,managers:[.metadata.managedFields[]?|"\(.manager)/\(.operation)"]}'
out=$(mk v2 | kubectl apply --server-side --field-manager=nagare-inventory -f - 2>&1); echo "present, rv \"0\": rc=$? ${out:0:200}"
