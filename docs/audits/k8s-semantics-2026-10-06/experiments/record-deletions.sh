#!/usr/bin/env bash
# EP-182 M1, experiment E14: delete every E1 object that record-traces.sh left
# in the cluster, with the propagation Nagare's collection uses for the kind
# (Background for Job and StatefulSet, Orphan for the other collectable kinds)
# or, for a kind Nagare never collects, the Background delete `kubectl delete`
# sends. Prints one JSON step per line on stdout, in record-traces.sh's step
# format; record-traces.sh runs it last and folds its lines into its document.
set -uo pipefail
: "${KUBECONFIG:?point at the cluster record-traces.sh used}"
NS=trace
log() { echo "record-deletions: $*" >&2; }
OBS='{present: true, uid: .metadata.uid, resourceVersion: .metadata.resourceVersion, generation: .metadata.generation,
 deletionTimestamp: (.metadata.deletionTimestamp != null), finalizers: (.metadata.finalizers // []), phase: .status.phase,
 managers: [.metadata.managedFields[]? | "\(.manager)/\(.operation)/\(.subresource // "-")"]}'
observe() { # resource name namespace|-
  local args=(); [ "$3" != - ] && args=(-n "$3")
  local out; out=$(kubectl get "$1" "$2" "${args[@]}" -o json --show-managed-fields --ignore-not-found 2>/dev/null)
  if [ -z "$out" ]; then echo '{"present":false}'; else echo "$out" | jq -c "$OBS"; fi
}
step() { jq -cn --arg k "$1" --arg s "$2" --argjson a "$3" --argjson o "$4" '{experiment:"E14", kind:$k, step:$s, action:$a, observation:$o, refusal:null}'; }

# kind | resource | name | namespace | API path | propagation
while IFS='|' read -r kind resource name ns path propagation; do
  [ -z "$kind" ] && continue
  log "$kind"
  args=(); [ "$ns" != - ] && args=(-n "$ns")
  group=$(case $kind in deployment|statefulset) echo apps;; cronjob|job) echo batch;; networkpolicy) echo networking.k8s.io;; role|rolebinding) echo rbac.authorization.k8s.io;; ksvc|domainmapping) echo serving.knative.dev;; *) echo "";; esac)
  target=$(jq -cn --arg g "$group" --arg k "$([ "$kind" = ksvc ] && echo service || echo "$kind")" --arg n "$name" --arg ns "$ns" '{group:$g, kind:$k, name:$n, namespace:(if $ns == "-" then null else $ns end)}')
  # Observe first, so a replay can map the UID and resourceVersion the delete
  # carries as its preconditions.
  seen=$(observe "$resource" "$name" "$ns")
  step "$kind" "before delete" "$(jq -cn --argjson t "$target" '{op:"observe",target:$t}')" "$seen"
  uid=$(echo "$seen" | jq -r '.uid // empty'); rv=$(echo "$seen" | jq -r '.resourceVersion // empty')
  if [ -z "${uid:-}" ]; then continue; fi
  body=$(jq -cn --arg u "$uid" --arg r "$rv" --arg p "$propagation" '{apiVersion:"meta.k8s.io/v1",kind:"DeleteOptions",preconditions:{uid:$u,resourceVersion:$r},propagationPolicy:$p}')
  kubectl delete --raw "$path" -f <(echo "$body") >/dev/null 2>&1
  action=$(jq -cn --argjson t "$target" --argjson o "$body" '{op:"delete",target:$t,options:$o}')
  step "$kind" "$propagation delete, immediately" "$action" "$(observe "$resource" "$name" "$ns")"
  sleep 5
  step "$kind" "$propagation delete, after 5s" '{"op":"wait","seconds":5}' "$(observe "$resource" "$name" "$ns")"
done <<EOF
configmap|configmap|e1|$NS|/api/v1/namespaces/$NS/configmaps/e1|Orphan
secret|secret|e1|$NS|/api/v1/namespaces/$NS/secrets/e1|Background
serviceaccount|serviceaccount|e1|$NS|/api/v1/namespaces/$NS/serviceaccounts/e1|Orphan
rolebinding|rolebinding|e1|$NS|/apis/rbac.authorization.k8s.io/v1/namespaces/$NS/rolebindings/e1|Orphan
role|role|e1|$NS|/apis/rbac.authorization.k8s.io/v1/namespaces/$NS/roles/e1|Orphan
networkpolicy|networkpolicy|e1|$NS|/apis/networking.k8s.io/v1/namespaces/$NS/networkpolicies/e1|Background
service|service|e1|$NS|/api/v1/namespaces/$NS/services/e1|Orphan
resourcequota|resourcequota|e1|$NS|/api/v1/namespaces/$NS/resourcequotas/e1|Background
persistentvolumeclaim|persistentvolumeclaim|e1|$NS|/api/v1/namespaces/$NS/persistentvolumeclaims/e1|Orphan
deployment|deployment|e1|$NS|/apis/apps/v1/namespaces/$NS/deployments/e1|Background
statefulset|statefulset|e1|$NS|/apis/apps/v1/namespaces/$NS/statefulsets/e1|Background
cronjob|cronjob|e1|$NS|/apis/batch/v1/namespaces/$NS/cronjobs/e1|Orphan
job|job|e1|$NS|/apis/batch/v1/namespaces/$NS/jobs/e1|Background
domainmapping|domainmappings.serving.knative.dev|e1.127-0-0-1.sslip.io|$NS|/apis/serving.knative.dev/v1beta1/namespaces/$NS/domainmappings/e1.127-0-0-1.sslip.io|Background
ksvc|services.serving.knative.dev|e1|$NS|/apis/serving.knative.dev/v1/namespaces/$NS/services/e1|Background
namespace|namespace|trace-ns|-|/api/v1/namespaces/trace-ns|Background
EOF
