#!/usr/bin/env bash
# EP-182 M1: replay RES-4's experiments against a disposable cluster and print
# their abstracted traces as one JSON document on stdout. Progress goes to
# stderr. The recovery model's kind table (Nagare.Test.World.Kinds) and its
# fake API server are checked against this output.
#
# Requires KUBECONFIG to point at a fresh k3d cluster running
# rancher/k3s:v1.34.6-k3s1 with one server and no Traefik. The script installs
# the vendored Knative Serving 1.22 and Kourier itself. It creates namespaces
# trace and trace-ns; delete the cluster afterwards. A run takes about 20 minutes
# on a 2-CPU, 4 GiB Colima VM. Regenerate the fixture with:
#   record-traces.sh > cli/nagarectl/test/fixtures/kubernetes-semantics/traces.json
#
# Every step records the action it took (as data a fake server can replay)
# and an observation of the object after it: generation, observedGeneration,
# resourceVersion, conditions and their reasons, replica counters, revision
# equality, deletionTimestamp, finalizers, phase and managed-field writers.
# Refusals record the HTTP status (from kubectl -v=6) and kubectl's first
# stderr line. UIDs and resourceVersions are kept raw; consumers compare them
# only within one object's sequence.
set -uo pipefail
: "${KUBECONFIG:?point at a disposable k3s v1.34.6 cluster}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
vendor="$root/cluster/bootstrap/vendor"
NS=trace
steps=$(mktemp)
trap 'rm -f "$steps"' EXIT
log() { echo "record-traces: $*" >&2; }

# The abstraction of one object, or {"present":false}.
OBS='def counters: (.status // {} | {replicas, updatedReplicas, readyReplicas, availableReplicas, currentReplicas, unavailableReplicas} | with_entries(select(.value != null)));
{present: true,
 uid: .metadata.uid,
 resourceVersion: .metadata.resourceVersion,
 generation: .metadata.generation,
 observedGeneration: .status.observedGeneration,
 conditions: ([.status.conditions[]? | {(.type): .status}] | add // {}),
 reasons: ([.status.conditions[]? | select(.reason != null and .reason != "") | {(.type): .reason}] | add // {}),
 counters: counters,
 revisionsEqual: (if .status.updateRevision then .status.updateRevision == .status.currentRevision else null end),
 deletionTimestamp: (.metadata.deletionTimestamp != null),
 finalizers: (.metadata.finalizers // []),
 phase: .status.phase,
 managers: [.metadata.managedFields[]? | "\(.manager)/\(.operation)/\(.subresource // "-")"]}'

observe() { # resource name [namespace|-]
  local ns=${3:-$NS} args=()
  [ "$ns" != - ] && args=(-n "$ns")
  local out
  out=$(kubectl get "$1" "$2" "${args[@]}" -o json --show-managed-fields --ignore-not-found 2>/dev/null)
  if [ -z "$out" ]; then echo '{"present":false}'; else echo "$out" | jq -c "$OBS"; fi
}

# step experiment kind step-label action-json observation-json [refusal-json]
step() {
  jq -cn --arg e "$1" --arg k "$2" --arg s "$3" --argjson a "$4" --argjson o "$5" --argjson r "${6:-null}" \
    '{experiment:$e, kind:$k, step:$s, action:$a, observation:$o, refusal:$r}' >> "$steps"
}

# Run a kubectl command; print {"status":N,"reason":R,"stderr":first-line,"exit":E}
# for a refusal, or null when it succeeded.
attempt() {
  local out rc
  out=$("$@" -v=6 2>&1); rc=$?
  if [ $rc -eq 0 ]; then echo null; return; fi
  local http first
  http=$(echo "$out" | grep -oE 'Response" verb="(POST|PUT|PATCH|DELETE)" url="[^"]*" status="[0-9]+ [A-Za-z ]+"' | tail -1 | sed -E 's/.*status="([0-9]+) ([A-Za-z ]+)"/\1|\2/')
  first=$(echo "$out" | grep -vE '^I[0-9]{4} ' | grep -E '^(Error|error|The )' | head -1)
  jq -cn --arg h "$http" --arg f "$first" --argjson e "$rc" \
    '{status: (($h | split("|")[0]) | tonumber? // null), reason: ($h | split("|")[1] // null), stderr: $f, exit: $e}'
}

apply_json() { kubectl apply --server-side --field-manager="${2:-exp}" -f <(echo "$1") >/dev/null 2>&1; }

# ---------------------------------------------------------------- setup
log "installing Knative Serving 1.22 and Kourier from $vendor"
kubectl apply -f "$vendor/serving-crds-v1.22.0.yaml" >/dev/null
kubectl wait --for=condition=established crd --all --timeout=120s >/dev/null
kubectl apply -f "$vendor/serving-core-v1.22.0.yaml" >/dev/null 2>&1
sleep 2
kubectl apply -f "$vendor/serving-core-v1.22.0.yaml" >/dev/null
kubectl apply -f "$vendor/kourier-v1.22.0.yaml" >/dev/null
kubectl patch configmap/config-network -n knative-serving --type merge \
  -p '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev","autocreate-cluster-domain-claims":"true"}}' >/dev/null
kubectl patch configmap/config-domain -n knative-serving --type merge -p '{"data":{"127-0-0-1.sslip.io":""}}' >/dev/null
kubectl -n knative-serving rollout status deploy --timeout=300s >/dev/null
kubectl -n kourier-system rollout status deploy --timeout=180s >/dev/null
kubectl create namespace $NS >/dev/null

# ---------------------------------------------------------------- E0
log "E0 status subresources"
discovery=$( { kubectl get --raw /api/v1; for g in apps/v1 batch/v1 networking.k8s.io/v1 rbac.authorization.k8s.io/v1 serving.knative.dev/v1 serving.knative.dev/v1beta1; do kubectl get --raw "/apis/$g"; done; } \
  | jq -s -c '[.[] | .groupVersion as $gv | .resources[] | select(.name | endswith("/status")) | {groupVersion: ($gv // "v1"), resource: .name}]')
step E0 "-" "status subresources" '{"op":"discover"}' "$discovery"

# ---------------------------------------------------------------- E1
manifest() { # kind variant name
  local n=${3:-e1}
  case $1 in
  configmap) jq -cn --arg v "v$2" --arg n "$n" '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:$n,namespace:"trace"},data:{k:$v}}';;
  secret) jq -cn --arg v "v$2" --arg n "$n" '{apiVersion:"v1",kind:"Secret",metadata:{name:$n,namespace:"trace"},stringData:{k:$v}}';;
  serviceaccount) jq -cn --argjson b "$([ "$2" = 1 ] && echo true || echo false)" --arg n "$n" '{apiVersion:"v1",kind:"ServiceAccount",metadata:{name:$n,namespace:"trace"},automountServiceAccountToken:$b}';;
  namespace) jq -cn --arg v "v$2" '{apiVersion:"v1",kind:"Namespace",metadata:{name:"trace-ns",labels:{v:$v}}}';;
  resourcequota) jq -cn --arg v "1$2" --arg n "$n" '{apiVersion:"v1",kind:"ResourceQuota",metadata:{name:$n,namespace:"trace"},spec:{hard:{pods:$v}}}';;
  networkpolicy) jq -cn --arg v "v$2" --arg n "$n" '{apiVersion:"networking.k8s.io/v1",kind:"NetworkPolicy",metadata:{name:$n,namespace:"trace"},spec:{podSelector:{matchLabels:{v:$v}},policyTypes:["Ingress"]}}';;
  role) jq -cn --argjson verbs "$([ "$2" = 1 ] && echo '["get"]' || echo '["get","list"]')" --arg n "$n" '{apiVersion:"rbac.authorization.k8s.io/v1",kind:"Role",metadata:{name:$n,namespace:"trace"},rules:[{apiGroups:[""],resources:["configmaps"],verbs:$verbs}]}';;
  rolebinding) jq -cn --argjson extra "$([ "$2" = 1 ] && echo '[]' || echo '[{"kind":"ServiceAccount","name":"default","namespace":"trace"}]')" --arg n "$n" '{apiVersion:"rbac.authorization.k8s.io/v1",kind:"RoleBinding",metadata:{name:$n,namespace:"trace"},roleRef:{apiGroup:"rbac.authorization.k8s.io",kind:"Role",name:"e1"},subjects:([{kind:"ServiceAccount",name:"e1",namespace:"trace"}] + $extra)}';;
  service) jq -cn --argjson p "8$2" --arg n "$n" '{apiVersion:"v1",kind:"Service",metadata:{name:$n,namespace:"trace"},spec:{selector:{app:"e1"},ports:[{port:$p,targetPort:8080}]}}';;
  persistentvolumeclaim) jq -cn --arg s "1$2Mi" --arg n "$n" '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$n,namespace:"trace"},spec:{accessModes:["ReadWriteOnce"],resources:{requests:{storage:$s}}}}';;
  deployment) jq -cn --arg v "v$2" --arg n "$n" '{apiVersion:"apps/v1",kind:"Deployment",metadata:{name:$n,namespace:"trace"},spec:{replicas:1,selector:{matchLabels:{app:($n+"-d")}},template:{metadata:{labels:{app:($n+"-d")},annotations:{v:$v}},spec:{containers:[{name:"c",image:"registry.k8s.io/pause:3.10"}]}}}}';;
  statefulset) jq -cn --arg v "v$2" --arg n "$n" '{apiVersion:"apps/v1",kind:"StatefulSet",metadata:{name:$n,namespace:"trace"},spec:{replicas:1,serviceName:$n,selector:{matchLabels:{app:($n+"-s")}},template:{metadata:{labels:{app:($n+"-s")},annotations:{v:$v}},spec:{terminationGracePeriodSeconds:1,containers:[{name:"c",image:"registry.k8s.io/pause:3.10"}]}}}}';;
  cronjob) jq -cn --arg v "v$2" --arg n "$n" '{apiVersion:"batch/v1",kind:"CronJob",metadata:{name:$n,namespace:"trace"},spec:{schedule:"0 0 1 1 *",suspend:true,jobTemplate:{spec:{template:{metadata:{annotations:{v:$v}},spec:{restartPolicy:"Never",containers:[{name:"c",image:"busybox:1.36",command:["true"]}]}}}}}}';;
  job) jq -cn --argjson s "$([ "$2" = 1 ] && echo true || echo false)" --arg n "$n" '{apiVersion:"batch/v1",kind:"Job",metadata:{name:$n,namespace:"trace"},spec:{suspend:$s,template:{spec:{restartPolicy:"Never",containers:[{name:"c",image:"busybox:1.36",command:["true"]}]}}}}';;
  ksvc) jq -cn --arg v "v$2" --arg n "$n" '{apiVersion:"serving.knative.dev/v1",kind:"Service",metadata:{name:$n,namespace:"trace"},spec:{template:{metadata:{annotations:{v:$v}},spec:{containers:[{image:"ghcr.io/knative/helloworld-go:latest",env:[{name:"TARGET",value:$v}]}]}}}}';;
  domainmapping) jq -cn --arg t "$([ "$2" = 1 ] && echo dm-target-a || echo dm-target-b)" '{apiVersion:"serving.knative.dev/v1beta1",kind:"DomainMapping",metadata:{name:"e1.127-0-0-1.sslip.io",namespace:"trace"},spec:{ref:{name:$t,kind:"Service",apiVersion:"serving.knative.dev/v1"}}}';;
  esac
}
resource_of() { case $1 in ksvc) echo services.serving.knative.dev;; domainmapping) echo domainmappings.serving.knative.dev;; *) echo "$1";; esac; }
name_of() { case $1 in namespace) echo trace-ns;; domainmapping) echo e1.127-0-0-1.sslip.io;; *) echo e1;; esac; }
ns_of() { [ "$1" = namespace ] && echo - || echo $NS; }
status_patch() {
  case $1 in
  deployment|statefulset) echo '{"status":{"collisionCount":7}}';;
  cronjob) echo '{"status":{"lastScheduleTime":"2026-01-01T00:00:00Z"}}';;
  resourcequota) echo '{"status":{"used":{"pods":"9"}}}';;
  namespace) echo '{"status":{"conditions":[{"type":"ExpProbe","status":"True"}]}}';;
  service) echo '{"status":{"conditions":[{"type":"ExpProbe","status":"True","reason":"R","message":"m","lastTransitionTime":"2026-01-01T00:00:00Z"}]}}';;
  persistentvolumeclaim) echo '{"status":{"conditions":[{"type":"Resizing","status":"True"}]}}';;
  ksvc|domainmapping) echo '{"status":{"annotations":{"exp":"probe"}}}';;
  *) echo "";;
  esac
}

# The DomainMapping's targets, and a PVC consumer so a bound PVC can be resized.
for t in dm-target-a dm-target-b; do apply_json "$(manifest ksvc 1 $t)"; done
kubectl wait --for=condition=ready services.serving.knative.dev/dm-target-a services.serving.knative.dev/dm-target-b -n $NS --timeout=180s >/dev/null

kinds=(configmap secret serviceaccount role rolebinding networkpolicy service resourcequota namespace persistentvolumeclaim deployment statefulset cronjob job ksvc domainmapping)
for k in "${kinds[@]}"; do
  log "E1 $k"
  r=$(resource_of $k); n=$(name_of $k); ns=$(ns_of $k)
  nsargs=(); [ "$ns" != - ] && nsargs=(-n "$ns")
  v1=$(manifest $k 1); v2=$(manifest $k 2)
  apply_json "$v1"; step E1 $k create "$(jq -cn --argjson m "$v1" '{op:"apply",manifest:$m}')" "$(observe $r $n $ns)"
  sleep 8; step E1 $k settle '{"op":"wait","seconds":8}' "$(observe $r $n $ns)"
  apply_json "$v1"; step E1 $k "no-op apply" "$(jq -cn --argjson m "$v1" '{op:"apply",manifest:$m}')" "$(observe $r $n $ns)"
  kubectl annotate $r $n "${nsargs[@]}" probe=1 >/dev/null; step E1 $k annotate '{"op":"annotate","key":"probe","value":"1"}' "$(observe $r $n $ns)"
  kubectl label $r $n "${nsargs[@]}" probe=1 >/dev/null; step E1 $k label '{"op":"label","key":"probe","value":"1"}' "$(observe $r $n $ns)"
  refusal=$(attempt kubectl apply --server-side --field-manager=exp -f <(echo "$v2"))
  step E1 $k "spec change" "$(jq -cn --argjson m "$v2" '{op:"apply",manifest:$m}')" "$(observe $r $n $ns)" "$refusal"
  sp=$(status_patch $k)
  if [ -n "$sp" ]; then
    refusal=$(attempt kubectl patch $r $n "${nsargs[@]}" --subresource=status --type=merge -p "$sp")
    step E1 $k "status write" "$(jq -cn --argjson p "$sp" '{op:"statusWrite",patch:$p}')" "$(observe $r $n $ns)" "$refusal"
  fi
  sleep 8; step E1 $k settle '{"op":"wait","seconds":8}' "$(observe $r $n $ns)"
done

# E10 baseline: the E1 objects are left untouched from here on; the final
# observation at the end of the run shows which kinds churned on their own.
# The CronJob below makes pods come and go in the namespace every minute.
apply_json "$(jq -cn '{apiVersion:"batch/v1",kind:"CronJob",metadata:{name:"e10-ticker",namespace:"trace"},spec:{schedule:"* * * * *",successfulJobsHistoryLimit:1,jobTemplate:{spec:{template:{spec:{restartPolicy:"Never",containers:[{name:"c",image:"busybox:1.36",command:["true"]}]}}}}}}')"
e10_start=$(date +%s)
declare -A e10_before
for k in "${kinds[@]}" ; do e10_before[$k]=$(observe "$(resource_of $k)" "$(name_of $k)" "$(ns_of $k)"); done
e10_ticker_before=$(observe cronjob e10-ticker)

# ---------------------------------------------------------------- E3
for k in configmap ksvc; do
  log "E3 $k"
  r=$(resource_of $k)
  cm() { # name rv uid value
    manifest $k 1 "$1" | jq -c --arg rv "$2" --arg uid "$3" --arg v "$4" \
      '.metadata += ((if $rv == "" then {} else {resourceVersion:$rv} end) + (if $uid == "" then {} else {uid:$uid} end))
       | if .kind == "ConfigMap" then .data.k = $v else .spec.template.spec.containers[0].env[0].value = $v end'
  }
  path=$([ $k = configmap ] && echo /api/v1/namespaces/$NS/configmaps || echo /apis/serving.knative.dev/v1/namespaces/$NS/services)
  kubectl delete $r e3 -n $NS --ignore-not-found >/dev/null
  kubectl create --field-manager=nagare-inventory -f <(cm e3 "" "" v1) >/dev/null 2>&1
  sleep 2
  uid=$(kubectl get $r e3 -n $NS -o jsonpath='{.metadata.uid}'); rv=$(kubectl get $r e3 -n $NS -o jsonpath='{.metadata.resourceVersion}')
  step E3 $k "baseline" '{"op":"create","manager":"nagare-inventory"}' "$(observe $r e3)"
  case3() { # label action-json command...
    local label=$1 action=$2; shift 2
    local refusal; refusal=$(attempt "$@")
    step E3 $k "$label" "$action" "$(observe $r e3)" "$refusal"
  }
  case3 "create existing" '{"op":"create","manager":"nagare-inventory"}' kubectl create -f <(cm e3 "" "" v9)
  case3 "apply current uid and rv" '{"op":"apply","preconditions":"current uid and rv"}' kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f <(cm e3 "$rv" "$uid" v2)
  rv2=$(kubectl get $r e3 -n $NS -o jsonpath='{.metadata.resourceVersion}')
  case3 "apply stale rv" '{"op":"apply","preconditions":"stale rv"}' kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f <(cm e3 "$rv" "$uid" v3)
  case3 "apply wrong uid" '{"op":"apply","preconditions":"wrong uid, current rv"}' kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f <(cm e3 "$rv2" 00000000-0000-0000-0000-000000000000 v4)
  case3 "replace stale rv" '{"op":"replace","preconditions":"stale rv"}' kubectl replace -f <(cm e3 "$rv" "$uid" v5)
  case3 "json patch test fails" '{"op":"patchJson","test":"stale rv"}' kubectl patch $r e3 -n $NS --type=json -p "[{\"op\":\"test\",\"path\":\"/metadata/resourceVersion\",\"value\":\"$rv\"},{\"op\":\"add\",\"path\":\"/metadata/annotations\",\"value\":{\"x\":\"y\"}}]"
  case3 "delete wrong uid" '{"op":"delete","preconditions":"wrong uid"}' kubectl delete --raw "$path/e3" -f <(jq -cn '{apiVersion:"meta.k8s.io/v1",kind:"DeleteOptions",preconditions:{uid:"00000000-0000-0000-0000-000000000000"}}')
  case3 "delete stale rv" '{"op":"delete","preconditions":"current uid, stale rv"}' kubectl delete --raw "$path/e3" -f <(jq -cn --arg u "$uid" --arg r "$rv" '{apiVersion:"meta.k8s.io/v1",kind:"DeleteOptions",preconditions:{uid:$u,resourceVersion:$r}}')
  rv3=$(kubectl get $r e3 -n $NS -o jsonpath='{.metadata.resourceVersion}')
  kubectl delete $r e3 -n $NS >/dev/null
  step E3 $k "deleted out of band" '{"op":"delete","propagation":"Background"}' "$(observe $r e3)"
  case3 "apply uid and rv on absent" '{"op":"apply","preconditions":"old uid and rv"}' kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f <(cm e3 "$rv3" "$uid" v6)
  kubectl delete $r e3 -n $NS --ignore-not-found >/dev/null
  case3 "apply rv only on absent" '{"op":"apply","preconditions":"old rv only"}' kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f <(cm e3 "$rv3" "" v7)
  kubectl delete $r e3 -n $NS --ignore-not-found >/dev/null
  case3 "apply uid only on absent" '{"op":"apply","preconditions":"old uid only"}' kubectl apply --server-side --force-conflicts --field-manager=nagare-inventory -f <(cm e3 "" "$uid" v8)
  case3 "delete absent" '{"op":"delete","preconditions":"old uid"}' kubectl delete --raw "$path/e3-absent" -f <(jq -cn --arg u "$uid" '{apiVersion:"meta.k8s.io/v1",kind:"DeleteOptions",preconditions:{uid:$u}}')
done

# ---------------------------------------------------------------- E13
log "E13 server-side apply ownership"
own() { jq -cn --arg v "$1" --arg d "$2" --arg uid "${3:-}" '{apiVersion:"v1",kind:"ConfigMap",metadata:({name:"e13",namespace:"trace",annotations:{"nagare.dev/spec-digest":$d}} + (if $uid == "" then {} else {uid:$uid} end)),data:{k:$v}}'; }
kubectl create --field-manager=nagare-inventory -f <(own v1 d1) >/dev/null
uid=$(kubectl get cm e13 -n $NS -o jsonpath='{.metadata.uid}')
step E13 configmap "created by kubectl create" '{"op":"create","manager":"nagare-inventory"}' "$(observe configmap e13)"
own13() { # label force(true|false) value digest
  local refusal flags=(--server-side --field-manager=nagare-inventory)
  [ "$2" = true ] && flags+=(--force-conflicts)
  refusal=$(attempt kubectl apply "${flags[@]}" -f <(own "$3" "$4" "$uid"))
  step E13 configmap "$1" "$(jq -cn --argjson f "$2" '{op:"apply",manager:"nagare-inventory",force:$f}')" "$(observe configmap e13)" "$refusal"
}
own13 "apply without force over the create entry" false v2 d2
own13 "forced apply" true v2 d2
own13 "apply without force after owning by apply" false v3 d3
kubectl patch cm e13 -n $NS --type=merge --field-manager=kubectl-edit -p '{"data":{"k":"edited"}}' >/dev/null
step E13 configmap "foreign edit of a managed field" '{"op":"patchMerge","manager":"kubectl-edit","patch":{"data":{"k":"edited"}}}' "$(observe configmap e13)"
own13 "apply without force after a foreign edit" false v4 d4
kubectl patch cm e13 -n $NS --type=merge --field-manager=kubectl-edit -p '{"data":{"k":"v3"}}' >/dev/null
step E13 configmap "foreign write restoring an earlier value" '{"op":"patchMerge","manager":"kubectl-edit","patch":{"data":{"k":"v3"}}}' "$(observe configmap e13)"
own13 "apply without force after a foreign write restoring an earlier value" false v5 d5
kubectl delete cm e13b -n $NS --ignore-not-found >/dev/null
zero() { jq -cn --arg v "$1" '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:"e13b",namespace:"trace",resourceVersion:"0"},data:{k:$v}}'; }
refusal=$(attempt kubectl apply --server-side --field-manager=nagare-inventory -f <(zero v1))
step E13 configmap "apply with resourceVersion 0 when absent" '{"op":"apply","preconditions":"rv 0"}' "$(observe configmap e13b)" "$refusal"
refusal=$(attempt kubectl apply --server-side --field-manager=nagare-inventory -f <(zero v2))
step E13 configmap "apply with resourceVersion 0 when present" '{"op":"apply","preconditions":"rv 0"}' "$(observe configmap e13b)" "$refusal"

# ---------------------------------------------------------------- E4
log "E4 Knative readiness against observedGeneration"
K=services.serving.knative.dev
kv() { jq -cn --arg v "$1" --arg img "${2:-ghcr.io/knative/helloworld-go:latest}" '{apiVersion:"serving.knative.dev/v1",kind:"Service",metadata:{name:"e4",namespace:"trace"},spec:{template:{spec:{containers:[{image:$img,env:[{name:"TARGET",value:$v}]}]}}}}'; }
apply_json "$(kv v1)"; kubectl wait --for=condition=ready $K/e4 -n $NS --timeout=180s >/dev/null
step E4 ksvc ready '{"op":"wait","until":"ready"}' "$(observe $K e4)"
kubectl -n knative-serving scale deploy/controller --replicas=0 >/dev/null
kubectl -n knative-serving rollout status deploy/controller --timeout=60s >/dev/null; sleep 3
apply_json "$(kv v2)"
step E4 ksvc "spec change, controller frozen" "$(jq -cn --argjson m "$(kv v2)" '{op:"apply",manifest:$m,controller:"frozen"}')" "$(observe $K e4)"
refusal=$(attempt kubectl wait --for=condition=ready $K/e4 -n $NS --timeout=5s)
step E4 ksvc "kubectl wait while frozen" '{"op":"kubectlWait","condition":"ready"}' "$(observe $K e4)" "$refusal"
kubectl -n knative-serving scale deploy/controller --replicas=1 >/dev/null
kubectl wait --for=condition=ready $K/e4 -n $NS --timeout=180s >/dev/null
step E4 ksvc "controller resumed, settled" '{"op":"wait","until":"ready"}' "$(observe $K e4)"
apply_json "$(kv v3 ghcr.io/knative/does-not-exist:nope)"
step E4 ksvc "bad image, immediately" "$(jq -cn --argjson m "$(kv v3 ghcr.io/knative/does-not-exist:nope)" '{op:"apply",manifest:$m}')" "$(observe $K e4)"
for _ in $(seq 1 60); do
  kubectl get $K e4 -n $NS -o json | jq -e '[.status.conditions[]? | select(.type == "Ready" and .status == "False")] | length > 0' >/dev/null && break
  sleep 1
done
step E4 ksvc "bad image, settled" '{"op":"wait","until":"ready false"}' "$(observe $K e4)"
refusal=$(attempt kubectl wait --for=condition=ready $K/e4 -n $NS --timeout=5s)
step E4 ksvc "kubectl wait on the bad revision" '{"op":"kubectlWait","condition":"ready"}' "$(observe $K e4)" "$refusal"

# ---------------------------------------------------------------- E5
log "E5 Deployment broken updates"
dep() { jq -cn --arg v "$1" --arg img "$2" --argjson cmd "${3:-null}" '{apiVersion:"apps/v1",kind:"Deployment",metadata:{name:"e5",namespace:"trace"},spec:{replicas:1,progressDeadlineSeconds:20,selector:{matchLabels:{app:"e5"}},template:{metadata:{labels:{app:"e5"},annotations:{v:$v}},spec:{terminationGracePeriodSeconds:1,containers:[({name:"c",image:$img} + (if $cmd then {command:$cmd} else {} end))]}}}}'; }
apply_json "$(dep good registry.k8s.io/pause:3.10)"; kubectl rollout status deploy/e5 -n $NS --timeout=120s >/dev/null
step E5 deployment "available" '{"op":"wait","until":"rolled out"}' "$(observe deployment e5)"
for variant in "bad-image|registry.invalid/nope:1|null" 'crash-loop|busybox:1.36|["sh","-c","exit 1"]'; do
  IFS='|' read -r label img cmd <<<"$variant"
  m=$(dep "$label" "$img" "$cmd")
  apply_json "$m"; sleep 2
  step E5 deployment "$label update, after 2s" "$(jq -cn --argjson m "$m" '{op:"apply",manifest:$m}')" "$(observe deployment e5)"
  sleep 30
  step E5 deployment "$label update, past the progress deadline" '{"op":"wait","seconds":30}' "$(observe deployment e5)"
  refusal=$(attempt kubectl rollout status deploy/e5 -n $NS --timeout=5s)
  step E5 deployment "$label update, rollout status" '{"op":"rolloutStatus"}' "$(observe deployment e5)" "$refusal"
  apply_json "$(dep good registry.k8s.io/pause:3.10)"; kubectl rollout status deploy/e5 -n $NS --timeout=120s >/dev/null
done

# ---------------------------------------------------------------- E6
log "E6 StatefulSet broken updates and corrections"
sts() { # name policy annotation image cmd cpu
  jq -cn --arg n "$1" --arg p "$2" --arg v "$3" --arg img "$4" --argjson cmd "${5:-null}" --arg cpu "${6:-10m}" \
    '{apiVersion:"apps/v1",kind:"StatefulSet",metadata:{name:$n,namespace:"trace"},spec:({replicas:1,serviceName:$n,selector:{matchLabels:{app:$n}},template:{metadata:{labels:{app:$n},annotations:{v:$v}},spec:{terminationGracePeriodSeconds:1,containers:[({name:"c",image:$img,resources:{requests:{cpu:$cpu}}} + (if $cmd then {command:$cmd} else {} end))]}}} + (if $p == "Parallel" then {podManagementPolicy:"Parallel"} else {} end))}'
}
pods() { kubectl get pods -n $NS -l app="$1" -o json | jq -c '[.items[] | {revision: .metadata.labels["controller-revision-hash"], ready: ([.status.conditions[]? | select(.type == "Ready") | .status] | first), phase: .status.phase}]'; }
sts_step() { # label name action
  step E6 statefulset "$1" "$3" "$(observe statefulset $2 | jq -c --argjson p "$(pods $2)" '. + {pods:$p}')"
}
CRASH='["sh","-c","exit 1"]'
for case in "e6a|OrderedReady|crash" "e6b|OrderedReady|pending" "e6c|Parallel|crash"; do
  IFS='|' read -r n policy breakage <<<"$case"
  good=$(sts $n $policy good registry.k8s.io/pause:3.10)
  apply_json "$good"; kubectl rollout status sts/$n -n $NS --timeout=120s >/dev/null
  sts_step "$policy: ready" $n '{"op":"wait","until":"rolled out"}'
  if [ $breakage = crash ]; then broken=$(sts $n $policy broken busybox:1.36 "$CRASH"); else broken=$(sts $n $policy broken registry.k8s.io/pause:3.10 null 64); fi
  apply_json "$broken"; sleep 20
  sts_step "$policy: $breakage update, after 20s" $n "$(jq -cn --argjson m "$broken" '{op:"apply",manifest:$m}')"
  fixed=$(sts $n $policy fixed registry.k8s.io/pause:3.10)
  apply_json "$fixed"; sleep 45
  sts_step "$policy: correcting update, after 45s" $n "$(jq -cn --argjson m "$fixed" '{op:"apply",manifest:$m}')"
  refusal=$(attempt kubectl rollout status sts/$n -n $NS --timeout=3s)
  sts_step "$policy: rollout status" $n '{"op":"rolloutStatus"}'
  if [ "$refusal" != null ]; then step E6 statefulset "$policy: rollout status refusal" '{"op":"rolloutStatus"}' '{"present":true}' "$refusal"; fi
  if [ $policy = OrderedReady ]; then
    kubectl delete pod $n-0 -n $NS --wait=false >/dev/null
    kubectl rollout status sts/$n -n $NS --timeout=60s >/dev/null
    sts_step "$policy: after deleting the stuck pod" $n '{"op":"deletePod","pod":0}'
  fi
done

# ---------------------------------------------------------------- E7 / E12
log "E7 and E12 deletion"
delete_with() { # api-path uid rv propagation
  jq -cn --arg u "$2" --arg r "$3" --arg p "$4" '{apiVersion:"meta.k8s.io/v1",kind:"DeleteOptions",preconditions:{uid:$u,resourceVersion:$r},propagationPolicy:$p}' > "$steps.del"
  kubectl delete --raw "$1" -f "$steps.del" >/dev/null 2>&1
}
deletion_case() { # kind resource name path propagation wait-seconds
  local uid rv; uid=$(kubectl get $2 $3 -n $NS -o jsonpath='{.metadata.uid}'); rv=$(kubectl get $2 $3 -n $NS -o jsonpath='{.metadata.resourceVersion}')
  delete_with "$4" "$uid" "$rv" "$5"
  step E7 $1 "$5 delete, immediately" "$(jq -cn --arg p "$5" '{op:"delete",propagation:$p,preconditions:"current uid and rv"}')" "$(observe $2 $3)"
  sleep "$6"
  step E7 $1 "$5 delete, after ${6}s" "$(jq -cn --argjson s "$6" '{op:"wait",seconds:$s}')" "$(observe $2 $3)"
}
apply_json "$(manifest configmap 1 e7)"; deletion_case configmap configmap e7 /api/v1/namespaces/$NS/configmaps/e7 Orphan 2
apply_json "$(manifest persistentvolumeclaim 1 e7)"
apply_json "$(jq -cn '{apiVersion:"v1",kind:"Pod",metadata:{name:"e7-user",namespace:"trace"},spec:{terminationGracePeriodSeconds:1,containers:[{name:"c",image:"registry.k8s.io/pause:3.10",volumeMounts:[{name:"d",mountPath:"/d"}]}],volumes:[{name:"d",persistentVolumeClaim:{claimName:"e7"}}]}}')"
kubectl wait --for=condition=ready pod/e7-user -n $NS --timeout=120s >/dev/null
deletion_case persistentvolumeclaim persistentvolumeclaim e7 /api/v1/namespaces/$NS/persistentvolumeclaims/e7 Orphan 10
kubectl delete pod e7-user -n $NS --wait=true >/dev/null; sleep 3
step E7 persistentvolumeclaim "after its consumer is deleted" '{"op":"deleteConsumer"}' "$(observe persistentvolumeclaim e7)"
apply_json "$(manifest ksvc 1 e7)"; kubectl wait --for=condition=ready $K/e7 -n $NS --timeout=180s >/dev/null
deletion_case ksvc $K e7 /apis/serving.knative.dev/v1/namespaces/$NS/services/e7 Orphan 30
apply_json "$(manifest ksvc 1 e7bg)"; kubectl wait --for=condition=ready $K/e7bg -n $NS --timeout=180s >/dev/null
deletion_case ksvc $K e7bg /apis/serving.knative.dev/v1/namespaces/$NS/services/e7bg Background 10
apply_json "$(manifest statefulset 1 e7)"; kubectl rollout status sts/e7 -n $NS --timeout=120s >/dev/null
deletion_case statefulset statefulset e7 /apis/apps/v1/namespaces/$NS/statefulsets/e7 Background 2
kubectl create namespace trace-del >/dev/null; kubectl create configmap x -n trace-del >/dev/null
kubectl delete namespace trace-del --wait=false >/dev/null
step E12 namespace "delete with contents, immediately" '{"op":"delete","propagation":"Background"}' "$(observe namespace trace-del -)"
kubectl wait --for=delete namespace/trace-del --timeout=60s >/dev/null
step E12 namespace "delete with contents, settled" '{"op":"wait","until":"deleted"}' "$(observe namespace trace-del -)"

# ---------------------------------------------------------------- E11
log "E11 quantities"
q_dep=$(jq -cn '{apiVersion:"apps/v1",kind:"Deployment",metadata:{name:"e11",namespace:"trace"},spec:{replicas:0,selector:{matchLabels:{app:"e11"}},template:{metadata:{labels:{app:"e11"}},spec:{containers:[{name:"c",image:"registry.k8s.io/pause:3.10",resources:{requests:{cpu:"1000m",memory:"1024Mi"},limits:{memory:"2048Mi",cpu:"1.5","ephemeral-storage":"1000M"}}}]}}}}')
apply_json "$q_dep"
step E11 deployment quantities "$(jq -cn --argjson m "$q_dep" '{op:"apply",manifest:$m}')" "$(kubectl get deploy e11 -n $NS -o json | jq -c '{present:true, resources: .spec.template.spec.containers[0].resources}')"
q_pvc=$(jq -cn '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:"e11",namespace:"trace"},spec:{accessModes:["ReadWriteOnce"],resources:{requests:{storage:"1024Mi"}}}}')
apply_json "$q_pvc"
step E11 persistentvolumeclaim quantities "$(jq -cn --argjson m "$q_pvc" '{op:"apply",manifest:$m}')" "$(kubectl get pvc e11 -n $NS -o json | jq -c '{present:true, resources: .spec.resources}')"
q_ksvc=$(jq -cn '{apiVersion:"serving.knative.dev/v1",kind:"Service",metadata:{name:"e11",namespace:"trace"},spec:{template:{spec:{containers:[{image:"ghcr.io/knative/helloworld-go:latest",resources:{requests:{memory:"1024Mi",cpu:"1000m"}}}]}}}}')
apply_json "$q_ksvc"
step E11 ksvc quantities "$(jq -cn --argjson m "$q_ksvc" '{op:"apply",manifest:$m}')" "$(kubectl get $K e11 -n $NS -o json | jq -c '{present:true, resources: .spec.template.spec.containers[0].resources}')"

# ---------------------------------------------------------------- E10
remaining=$(( 150 - ($(date +%s) - e10_start) ))
[ $remaining -gt 0 ] && { log "E10 waiting ${remaining}s for the churn window"; sleep $remaining; }
log "E10 steady-state churn"
window=$(( $(date +%s) - e10_start ))
for k in "${kinds[@]}"; do
  step E10 $k "unattended for ${window}s" "$(jq -cn --argjson b "${e10_before[$k]}" --argjson s "$window" '{op:"wait",seconds:$s,before:$b}')" "$(observe "$(resource_of $k)" "$(name_of $k)" "$(ns_of $k)")"
done
step E10 cronjob "a running schedule, unattended for ${window}s" "$(jq -cn --argjson b "$e10_ticker_before" --argjson s "$window" '{op:"wait",seconds:$s,before:$b,schedule:"* * * * *"}')" "$(observe cronjob e10-ticker)"

# ---------------------------------------------------------------- E14
log "E14 deletion of every E1 object"
"$here/record-deletions.sh" >> "$steps"
rm -f "$steps.del"

server=$(kubectl version -o json | jq -r .serverVersion.gitVersion)
client=$(kubectl version -o json | jq -r .clientVersion.gitVersion)
# One step per line, so a re-recording diffs step by step.
jq -cn --arg server "$server" --arg client "$client" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{recordedAt:$at, serverVersion:$server, kubectlVersion:$client, knative:"1.22.0"}' | sed 's/}$/,"steps":[/'
sed '$!s/$/,/' "$steps"
echo ']}'
log "done: $(wc -l < "$steps") steps"
