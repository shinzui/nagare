export KUBECONFIG=${KUBECONFIG:?point at a disposable k3s v1.34 + Knative 1.22 cluster}
NS=exp
snap() { # kind name [label]
  kubectl get "$1" "$2" -n $NS -o json 2>/dev/null | jq -c --arg l "${3:-}" '{l:$l, uid:.metadata.uid[0:8], rv:.metadata.resourceVersion, gen:.metadata.generation, og:.status.observedGeneration, conds:[.status.conditions[]?|"\(.type)=\(.status)"+(if .observedGeneration then "@\(.observedGeneration)" else "" end)+(if .reason then "(\(.reason))" else "" end)], dt:.metadata.deletionTimestamp, fin:.metadata.finalizers, phase:.status.phase}' || echo "{\"l\":\"${3:-}\",\"absent\":true}"
}
