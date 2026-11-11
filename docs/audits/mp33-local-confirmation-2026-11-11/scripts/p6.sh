. "$(dirname "$0")/lib.sh"; ids
REV="$(cat "$R/revision")"; IMAGE_REF="k3d-registry.localhost:5000/nagarectl-deployer:${REV:0:8}"
# The arm64 tooling package carries no platform payload (EP-253); the deployer image adds the packaged one.
docker tag "nagarectl-deployer:${REV:0:8}" "localhost:5000/nagarectl-deployer:${REV:0:8}"
docker push "localhost:5000/nagarectl-deployer:${REV:0:8}" | tail -1
step "P6a EP-251 D7: the operator publishes v2 and saves a review it does not yet apply"
out="$(OP app image-plan --archive "$R/hello-v1.tar" --destination "$IMG/op-hello:v2" --key op-hello-v2)"; printf '%s\n' "$out" | tail -2
setid OP_IMAGE_V2 "$(printf '%s\n' "$out" | imageid)"; ids
rm -rf "$R/reviews/op-hello-v2"
( cd "$R/fixtures/op" && run OP app deploy -f nagare/Config.hs --tag v2 --image-resource "$OP_IMAGE_V2" --save-plan "$R/reviews/op-hello-v2" | tail -2 )
OP inventory store status --json | jq -c '{generation}'

step "P6b EP-251 D7 / EP-247 D9: a deployer Pod in the cluster applies a second change through the object store"
K -n default delete pod mp33-deployer --ignore-not-found --wait >/dev/null
K -n default create serviceaccount mp33-ci --dry-run=client -o yaml | K apply -f - >/dev/null
# Fixture Kubernetes credential: cluster-admin (EP-248 issues the least-privilege one).
K create clusterrolebinding mp33-ci-fixture --clusterrole=cluster-admin --serviceaccount=default:mp33-ci --dry-run=client -o yaml | K apply -f - >/dev/null
bundle="$R/pod-bundle"; rm -rf "$bundle"; mkdir -m 700 "$bundle"
cp "$CIHOME/config/nagare/contexts/mp33.env" "$bundle/mp33.env"
cp "$CIHOME/store-credentials.json" "$bundle/store-credentials.json"
cp "$R/rendered/worker.json" "$bundle/worker.json"
ca="$(K -n default get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' | base64 | tr -d '\n')"
token="$(K -n default create token mp33-ci --duration 2h)"
( umask 077; cat > "$bundle/kubeconfig.yaml" <<YAML
apiVersion: v1
kind: Config
clusters: [{name: mp33, cluster: {server: "https://kubernetes.default.svc", certificate-authority-data: "$ca"}}]
users: [{name: mp33-ci, user: {token: "$token"}}]
contexts: [{name: mp33, context: {cluster: mp33, user: mp33-ci}}]
current-context: mp33
YAML
)
unset token
cat > "$bundle/run.sh" <<'SH'
set -euo pipefail
mkdir -p "$HOME/.config/nagare/contexts" "$HOME/.config/nagare/kubeconfigs" "$TMPDIR"
cp /bundle/mp33.env "$HOME/.config/nagare/contexts/mp33.env"
cp /bundle/kubeconfig.yaml "$HOME/.config/nagare/kubeconfigs/mp33.yaml"
cp /bundle/store-credentials.json "$HOME/store-credentials.json"; chmod 600 "$HOME/store-credentials.json" "$HOME/.config/nagare/kubeconfigs/mp33.yaml"
export NAGARE_INVENTORY_STORE_CREDENTIALS_FILE="$HOME/store-credentials.json" KUBECONFIG="$HOME/.config/nagare/kubeconfigs/mp33.yaml"
echo "pod: $(id) on $(uname -m), KUBERNETES_SERVICE_HOST=$KUBERNETES_SERVICE_HOST"
nagarectl version --json
nagarectl --context mp33 inventory history --limit 2
nagarectl --context mp33 worker deploy --rendered /bundle/worker.json --tag v1 --image-resource "$HELLO_IMAGE" \
  --source-repository https://forge.example.test/team-a/ticker --source-revision feedface --source-run https://ci.example.test/runs/43
nagarectl --context mp33 inventory history --limit 3
SH
K -n default delete secret mp33-ci-bundle --ignore-not-found >/dev/null
K -n default create secret generic mp33-ci-bundle --from-file="$bundle" >/dev/null
rm -f "$bundle/kubeconfig.yaml" "$bundle/store-credentials.json"
K apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata: {name: mp33-deployer, namespace: default}
spec:
  serviceAccountName: mp33-ci
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: deploy
    image: $IMAGE_REF
    command: ["/bin/bash", "/bundle/run.sh"]
    env: [{name: HELLO_IMAGE, value: "$HELLO_IMAGE"}]
    securityContext: {readOnlyRootFilesystem: true, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    resources: {requests: {cpu: 500m, memory: 512Mi}, limits: {cpu: "2", memory: 2Gi}}
    volumeMounts: [{name: work, mountPath: /work}, {name: bundle, mountPath: /bundle, readOnly: true}]
  volumes:
  - {name: work, emptyDir: {}}
  - {name: bundle, secret: {secretName: mp33-ci-bundle, defaultMode: 0440}}
YAML
phase=""
for _ in $(seq 1 600); do phase="$(K -n default get pod mp33-deployer -o jsonpath='{.status.phase}')"; case "$phase" in Succeeded|Failed) break ;; esac; sleep 1; done
K -n default logs mp33-deployer
[ "$phase" = Succeeded ] || { echo "UNEXPECTED: the deployer Pod ended $phase" >&2; exit 1; }
K -n default delete secret mp33-ci-bundle >/dev/null
K -n team-a rollout status deploy/ticker --timeout=300s 2>/dev/null || K -n team-a get deploy,pods
run K -n team-a logs deploy/ticker --tail=2

step "P6c EP-251 D7 / EP-247 D11: the operator's saved review is refused as stale, then re-planned and applied"
OP inventory store status --json | jq -c '{generation}'
refused OP inventory apply "$R/reviews/op-hello-v2" --yes --contract 1
rm -rf "$R/reviews/op-hello-v2b"
( cd "$R/fixtures/op" && run OP app deploy -f nagare/Config.hs --tag v2 --image-resource "$OP_IMAGE_V2" --save-plan "$R/reviews/op-hello-v2b" | tail -2 )
run OP inventory apply "$R/reviews/op-hello-v2b" --yes 2>&1 | tail -2
run K -n personal get ksvc op-hello -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
